#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#endif

#ifdef __linux__
#include <dirent.h>
#endif

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define DB_PROTOCOL_MAX 2048
#define DB_STATUS_MAX 1024
#define DB_PATH_MAX 240
#define DB_FAILURE_MAX 16
#define DB_HEARTBEAT_TIMEOUT_MS 15000ULL
#define DB_STARTUP_TIMEOUT_MS 30000ULL
#define DB_TERMINATE_GRACE_MS 5000ULL
#define DB_MAINTENANCE_MAX_SECONDS 3600ULL
#define DB_CRASH_WINDOW_MS 300000ULL
/* Cold boot: launchd starts this daemon long before SpringBoard exists. */
#define DB_BOOT_GRACE_MS 20000ULL
/* Bounded re-open interval for a present app that never starts its heartbeat. */
#define DB_ACTIVATE_INTERVAL_MS 15000ULL
/* Bounded re-scan interval for the fixed process-presence probe. */
#define DB_PRESENCE_SCAN_MS 1000ULL
/* Absolute cap on launches performed while safe mode is latched. */
#define DB_SAFE_MODE_LAUNCH_CAP 10U
/* Default bound for the launchd-redirected stderr log. */
#define DB_LOG_MAX_BYTES_DEFAULT 262144ULL
/* Fixed process names; never derived from configuration or the network. */
#define DB_UI_PROCESS_NAME "SpringBoard"
#define DB_APP_PROCESS_NAME "Doorbell"

typedef enum {
  DB_MODE_OFF,
  DB_MODE_AUTO,
  DB_MODE_ON,
} db_mode;

typedef enum {
  DB_PROFILE_IOS5,
  DB_PROFILE_ANDROID,
#ifdef DB_KEEPALIVE_TESTING
  DB_PROFILE_TEST,
#endif
} db_profile;

typedef enum {
  DB_EVENT_STARTED,
  DB_EVENT_HEARTBEAT,
  DB_EVENT_MEMORY_PRESSURE,
  DB_EVENT_STOPPING,
} db_event;

typedef struct {
  db_event event;
  pid_t pid;
  uint64_t sequence;
  db_mode policy;
} db_message;

typedef struct {
  const char *socket_path;
  const char *status_path;
  const char *marker_path;
  const char *mode_path;
  const char *disable_path;
  db_mode mode;
  db_profile profile;
  uid_t app_uid;
  gid_t socket_gid;
  bool socket_gid_set;
  uint64_t heartbeat_timeout_ms;
  uint64_t startup_timeout_ms;
  uint64_t terminate_grace_ms;
  uint64_t boot_grace_ms;
  uint64_t activate_interval_ms;
  uint64_t log_max_bytes;
  unsigned int safe_mode_launch_cap;
  double time_scale;
#ifdef DB_KEEPALIVE_TESTING
  const char *test_exec;
  const char *test_process_file;
  bool test_stream;
#endif
} db_config;

typedef struct {
  db_config config;
  int socket_fd;
  bool peer_credentials_enforced;
  bool armed;
  bool safe_mode;
  bool waiting_start;
  bool stopping;
  bool disabled_by_file;
  bool launch_inhibited;
  bool expected_exit;
  bool maintenance_exit_grace;
  bool ui_ready;
  bool presence_valid;
  bool presence_present;
  pid_t app_pid;
  pid_t terminating_pid;
  pid_t launcher_pid;
  pid_t nudge_pid;
  uint64_t next_activate_ms;
  unsigned int activation_nudges;
  uint64_t last_sequence;
  uint64_t last_heartbeat_ms;
  uint64_t startup_deadline_ms;
  uint64_t next_restart_ms;
  uint64_t termination_deadline_ms;
  uint64_t maintenance_deadline_ms;
  uint64_t boot_grace_deadline_ms;
  uint64_t presence_checked_ms;
  uint64_t failures[DB_FAILURE_MAX];
  size_t failure_count;
  size_t backoff_index;
  unsigned int safe_mode_launches;
  const char *last_reason;
  bool status_dirty;
} db_state;

typedef struct {
  const char *cursor;
  const char *end;
} db_parser;

static bool db_presence_gate_enabled(const db_state *state);

static volatile sig_atomic_t db_should_stop = 0;

static void db_on_signal(int signal_number) {
  (void)signal_number;
  db_should_stop = 1;
}

static uint64_t db_now_ms(void) {
#ifdef __APPLE__
  static mach_timebase_info_data_t info;
  uint64_t ticks;
  if (info.denom == 0) mach_timebase_info(&info);
  ticks = mach_absolute_time();
  return (ticks / 1000000ULL) * info.numer / info.denom +
         ((ticks % 1000000ULL) * info.numer / info.denom) / 1000000ULL;
#else
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
  return (uint64_t)value.tv_sec * 1000ULL + (uint64_t)value.tv_nsec / 1000000ULL;
#endif
}

/* launchd redirects stdout/stderr into one file that nothing else rotates, so the
   helper caps its own log. When stderr is not a regular file (host tests, a pipe)
   the cap is a no-op and the caller's own bounds apply. */
static uint64_t db_log_limit = DB_LOG_MAX_BYTES_DEFAULT;

static void db_log_rotate(void) {
  struct stat metadata;
  if (db_log_limit == 0) return;
  if (fstat(STDERR_FILENO, &metadata) != 0 || !S_ISREG(metadata.st_mode)) return;
  if ((uint64_t)metadata.st_size < db_log_limit) return;
  if (ftruncate(STDERR_FILENO, 0) != 0) return;
  if (lseek(STDERR_FILENO, 0, SEEK_SET) == (off_t)-1) return;
  fprintf(stderr, "doorbell-keepalive: log truncated at %llu bytes\n",
          (unsigned long long)db_log_limit);
}

static void db_log(const char *format, ...) {
  va_list arguments;
  db_log_rotate();
  va_start(arguments, format);
  (void)vfprintf(stderr, format, arguments);
  va_end(arguments);
}

static const char *db_mode_name(db_mode mode) {
  switch (mode) {
    case DB_MODE_OFF: return "off";
    case DB_MODE_AUTO: return "auto";
    case DB_MODE_ON: return "on";
  }
  return "off";
}

static bool db_parse_mode(const char *value, db_mode *mode) {
  if (strcmp(value, "off") == 0) *mode = DB_MODE_OFF;
  else if (strcmp(value, "auto") == 0) *mode = DB_MODE_AUTO;
  else if (strcmp(value, "on") == 0) *mode = DB_MODE_ON;
  else return false;
  return true;
}

static bool db_parse_u64(const char *value, uint64_t *result) {
  char *end = NULL;
  unsigned long long parsed;
  if (value[0] == '\0' || value[0] == '-') return false;
  errno = 0;
  parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0') return false;
  *result = (uint64_t)parsed;
  return true;
}

static bool db_valid_path(const char *path, size_t maximum) {
  size_t length;
  if (path == NULL || path[0] != '/') return false;
  length = strlen(path);
  return length > 1 && length < maximum && strstr(path, "/../") == NULL &&
         (length < 3 || strcmp(path + length - 3, "/..") != 0);
}

static void db_skip_space(db_parser *parser) {
  while (parser->cursor < parser->end &&
         (*parser->cursor == ' ' || *parser->cursor == '\t' ||
          *parser->cursor == '\r' || *parser->cursor == '\n')) {
    parser->cursor++;
  }
}

static bool db_take(db_parser *parser, char expected) {
  db_skip_space(parser);
  if (parser->cursor >= parser->end || *parser->cursor != expected) return false;
  parser->cursor++;
  return true;
}

static bool db_parse_string(db_parser *parser, char *output, size_t capacity) {
  size_t used = 0;
  db_skip_space(parser);
  if (parser->cursor >= parser->end || *parser->cursor++ != '"') return false;
  while (parser->cursor < parser->end && *parser->cursor != '"') {
    unsigned char value = (unsigned char)*parser->cursor++;
    if (value < 0x20 || value == '\\' || used + 1 >= capacity) return false;
    output[used++] = (char)value;
  }
  if (parser->cursor >= parser->end || *parser->cursor++ != '"') return false;
  output[used] = '\0';
  return true;
}

static bool db_parse_number_token(db_parser *parser, char *output, size_t capacity) {
  const char *start;
  size_t length;
  db_skip_space(parser);
  start = parser->cursor;
  if (parser->cursor < parser->end && *parser->cursor == '-') parser->cursor++;
  if (parser->cursor >= parser->end || *parser->cursor < '0' ||
      *parser->cursor > '9') return false;
  while (parser->cursor < parser->end && *parser->cursor >= '0' &&
         *parser->cursor <= '9') parser->cursor++;
  if (parser->cursor < parser->end && *parser->cursor == '.') {
    parser->cursor++;
    if (parser->cursor >= parser->end || *parser->cursor < '0' ||
        *parser->cursor > '9') return false;
    while (parser->cursor < parser->end && *parser->cursor >= '0' &&
           *parser->cursor <= '9') parser->cursor++;
  }
  if (parser->cursor < parser->end &&
      (*parser->cursor == 'e' || *parser->cursor == 'E')) {
    parser->cursor++;
    if (parser->cursor < parser->end &&
        (*parser->cursor == '+' || *parser->cursor == '-')) parser->cursor++;
    if (parser->cursor >= parser->end || *parser->cursor < '0' ||
        *parser->cursor > '9') return false;
    while (parser->cursor < parser->end && *parser->cursor >= '0' &&
           *parser->cursor <= '9') parser->cursor++;
  }
  length = (size_t)(parser->cursor - start);
  if (length == 0 || length >= capacity) return false;
  memcpy(output, start, length);
  output[length] = '\0';
  return true;
}

enum {
  DB_SEEN_PROTOCOL = 1U << 0,
  DB_SEEN_EVENT = 1U << 1,
  DB_SEEN_PID = 1U << 2,
  DB_SEEN_BUNDLE = 1U << 3,
  DB_SEEN_APP_VERSION = 1U << 4,
  DB_SEEN_ROLE = 1U << 5,
  DB_SEEN_POLICY = 1U << 6,
  DB_SEEN_STATE = 1U << 7,
  DB_SEEN_SEQUENCE = 1U << 8,
  DB_SEEN_MEMORY = 1U << 9,
  DB_SEEN_UNIX_TIME = 1U << 10,
};

static bool db_set_seen(unsigned int *seen, unsigned int bit) {
  if ((*seen & bit) != 0) return false;
  *seen |= bit;
  return true;
}

static bool db_parse_message(const char *data, size_t length, db_message *message) {
  const unsigned int required = (1U << 11) - 1U;
  db_parser parser = {data, data + length};
  unsigned int seen = 0;
  char key[32];
  char string_value[192];
  char number_value[64];
  bool first = true;
  memset(message, 0, sizeof(*message));
  if (!db_take(&parser, '{')) return false;
  while (true) {
    db_skip_space(&parser);
    if (parser.cursor < parser.end && *parser.cursor == '}') {
      parser.cursor++;
      break;
    }
    if (!first && !db_take(&parser, ',')) return false;
    first = false;
    if (!db_parse_string(&parser, key, sizeof(key)) || !db_take(&parser, ':'))
      return false;

    if (strcmp(key, "protocol") == 0) {
      uint64_t value;
      if (!db_set_seen(&seen, DB_SEEN_PROTOCOL) ||
          !db_parse_number_token(&parser, number_value, sizeof(number_value)) ||
          !db_parse_u64(number_value, &value) || value != 1) return false;
    } else if (strcmp(key, "event") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_EVENT) ||
          !db_parse_string(&parser, string_value, sizeof(string_value))) return false;
      if (strcmp(string_value, "started") == 0) message->event = DB_EVENT_STARTED;
      else if (strcmp(string_value, "heartbeat") == 0)
        message->event = DB_EVENT_HEARTBEAT;
      else if (strcmp(string_value, "memory_pressure") == 0)
        message->event = DB_EVENT_MEMORY_PRESSURE;
      else if (strcmp(string_value, "stopping") == 0)
        message->event = DB_EVENT_STOPPING;
      else return false;
    } else if (strcmp(key, "pid") == 0) {
      uint64_t value;
      if (!db_set_seen(&seen, DB_SEEN_PID) ||
          !db_parse_number_token(&parser, number_value, sizeof(number_value)) ||
          !db_parse_u64(number_value, &value) || value == 0 || value > 2147483647ULL)
        return false;
      message->pid = (pid_t)value;
    } else if (strcmp(key, "bundle_id") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_BUNDLE) ||
          !db_parse_string(&parser, string_value, sizeof(string_value)) ||
          strcmp(string_value, "jp.ox.doorbell") != 0) return false;
    } else if (strcmp(key, "app_version") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_APP_VERSION) ||
          !db_parse_string(&parser, string_value, 81) || string_value[0] == '\0')
        return false;
    } else if (strcmp(key, "role") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_ROLE) ||
          !db_parse_string(&parser, string_value, 81) || string_value[0] == '\0')
        return false;
    } else if (strcmp(key, "policy") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_POLICY) ||
          !db_parse_string(&parser, string_value, sizeof(string_value)) ||
          !db_parse_mode(string_value, &message->policy) ||
          message->policy == DB_MODE_OFF) return false;
    } else if (strcmp(key, "state") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_STATE) ||
          !db_parse_string(&parser, string_value, 121) || string_value[0] == '\0')
        return false;
    } else if (strcmp(key, "sequence") == 0) {
      if (!db_set_seen(&seen, DB_SEEN_SEQUENCE) ||
          !db_parse_number_token(&parser, number_value, sizeof(number_value)) ||
          !db_parse_u64(number_value, &message->sequence) || message->sequence == 0)
        return false;
    } else if (strcmp(key, "memory_warnings") == 0) {
      uint64_t value;
      if (!db_set_seen(&seen, DB_SEEN_MEMORY) ||
          !db_parse_number_token(&parser, number_value, sizeof(number_value)) ||
          !db_parse_u64(number_value, &value)) return false;
    } else if (strcmp(key, "unix_time") == 0) {
      char *end = NULL;
      double value;
      if (!db_set_seen(&seen, DB_SEEN_UNIX_TIME) ||
          !db_parse_number_token(&parser, number_value, sizeof(number_value))) return false;
      errno = 0;
      value = strtod(number_value, &end);
      if (errno != 0 || end == number_value || *end != '\0' || value < 0) return false;
    } else {
      return false;
    }
  }
  db_skip_space(&parser);
  return parser.cursor == parser.end && seen == required;
}

static bool db_pid_uid_matches(pid_t pid, uid_t expected_uid) {
#ifdef __linux__
  char path[64];
  char buffer[1024];
  ssize_t length;
  int descriptor;
  char *uid_line;
  unsigned long real_uid;
  snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid);
  descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) return false;
  length = read(descriptor, buffer, sizeof(buffer) - 1);
  close(descriptor);
  if (length <= 0) return false;
  buffer[length] = '\0';
  uid_line = strstr(buffer, "\nUid:");
  if (uid_line != NULL) uid_line++;
  else if (strncmp(buffer, "Uid:", 4) == 0) uid_line = buffer;
  if (uid_line == NULL || sscanf(uid_line + 4, "%lu", &real_uid) != 1) return false;
  return (uid_t)real_uid == expected_uid;
#elif defined(__APPLE__)
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc process;
  size_t length = sizeof(process);
  memset(&process, 0, sizeof(process));
  if (sysctl(mib, 4, &process, &length, NULL, 0) != 0 || length == 0) return false;
  return process.kp_eproc.e_ucred.cr_uid == expected_uid;
#else
  return getuid() == expected_uid && (kill(pid, 0) == 0 || errno == EPERM);
#endif
}

static bool db_pid_alive(pid_t pid) {
  if (pid <= 0) return false;
  if (kill(pid, 0) == 0) return true;
  return errno == EPERM;
}

/* Fixed-name process presence probe.
   iOS 5 exposes no launchd query reachable from C99 and `uiopen` silently fails
   before SpringBoard exists, so the helper walks the kernel process table for two
   compiled-in names owned by the configured application UID. Names are never taken
   from configuration, the environment, or the network, and nothing is executed. */
static void db_scan_process_table(const char *ui_name, const char *app_name,
                                  uid_t expected_uid, bool *ui_present,
                                  bool *app_present) {
  *ui_present = false;
  *app_present = false;
#if defined(__APPLE__)
  {
    int mib[3];
    struct kinfo_proc *entries;
    size_t length = 0;
    size_t count;
    size_t index;
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_ALL;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return;
    /* The table can grow between sizing and reading; ask for headroom. */
    length += length / 8 + sizeof(struct kinfo_proc);
    entries = (struct kinfo_proc *)malloc(length);
    if (entries == NULL) return;
    if (sysctl(mib, 3, entries, &length, NULL, 0) != 0) {
      free(entries);
      return;
    }
    count = length / sizeof(struct kinfo_proc);
    for (index = 0; index < count; ++index) {
      const struct kinfo_proc *entry = &entries[index];
      if (entry->kp_proc.p_pid <= 0) continue;
      /* A zombie is not a running app; treating one as present would stall
         every relaunch until its parent reaped it. */
      if (entry->kp_proc.p_stat == SZOMB) continue;
      if (entry->kp_eproc.e_ucred.cr_uid != expected_uid) continue;
      if (!*ui_present &&
          strncmp(entry->kp_proc.p_comm, ui_name, sizeof(entry->kp_proc.p_comm)) == 0)
        *ui_present = true;
      if (!*app_present &&
          strncmp(entry->kp_proc.p_comm, app_name, sizeof(entry->kp_proc.p_comm)) == 0)
        *app_present = true;
      if (*ui_present && *app_present) break;
    }
    free(entries);
  }
#elif defined(__linux__)
  {
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    if (directory == NULL) return;
    while ((entry = readdir(directory)) != NULL) {
      char path[64];
      char name[64];
      char *end = NULL;
      long pid;
      int descriptor;
      ssize_t length;
      errno = 0;
      pid = strtol(entry->d_name, &end, 10);
      if (errno != 0 || end == entry->d_name || *end != '\0' || pid <= 0) continue;
      snprintf(path, sizeof(path), "/proc/%ld/comm", pid);
      descriptor = open(path, O_RDONLY | O_CLOEXEC);
      if (descriptor < 0) continue;
      length = read(descriptor, name, sizeof(name) - 1);
      close(descriptor);
      if (length <= 0) continue;
      name[length] = '\0';
      if (name[length - 1] == '\n') name[length - 1] = '\0';
      if (!db_pid_uid_matches((pid_t)pid, expected_uid)) continue;
      if (strcmp(name, ui_name) == 0) *ui_present = true;
      if (strcmp(name, app_name) == 0) *app_present = true;
      if (*ui_present && *app_present) break;
    }
    closedir(directory);
  }
#else
  (void)ui_name;
  (void)app_name;
  (void)expected_uid;
#endif
}

static bool db_write_all(int descriptor, const char *data, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t written = write(descriptor, data + offset, length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return false;
    offset += (size_t)written;
  }
  return true;
}

static bool db_fsync_parent_directory(const char *path) {
  char parent[DB_PATH_MAX];
  const char *separator = strrchr(path, '/');
  size_t length;
  int descriptor;
  int result;
  if (separator == NULL) {
    snprintf(parent, sizeof(parent), ".");
  } else {
    length = separator == path ? 1 : (size_t)(separator - path);
    if (length >= sizeof(parent)) {
      errno = ENAMETOOLONG;
      return false;
    }
    memcpy(parent, path, length);
    parent[length] = '\0';
  }
  descriptor = open(parent, O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) return false;
  result = fsync(descriptor);
  if (result != 0 && (errno == EINVAL || errno == ENOTSUP)) result = 0;
  if (close(descriptor) != 0 && result == 0) return false;
  return result == 0;
}

static bool db_atomic_write(const char *path, const char *data, mode_t mode) {
  char temporary[DB_PATH_MAX + 48];
  int descriptor;
  struct stat existing;
  if (lstat(path, &existing) == 0 && S_ISLNK(existing.st_mode)) {
    errno = ELOOP;
    return false;
  }
  if (snprintf(temporary, sizeof(temporary), "%s.tmp.%ld", path, (long)getpid()) >=
      (int)sizeof(temporary)) {
    errno = ENAMETOOLONG;
    return false;
  }
  descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                    mode);
  if (descriptor < 0) return false;
  if (fchmod(descriptor, mode) != 0 ||
      !db_write_all(descriptor, data, strlen(data)) || fsync(descriptor) != 0) {
    int saved = errno;
    close(descriptor);
    unlink(temporary);
    errno = saved;
    return false;
  }
  if (close(descriptor) != 0) {
    int saved = errno;
    unlink(temporary);
    errno = saved;
    return false;
  }
  if (rename(temporary, path) != 0) {
    int saved = errno;
    unlink(temporary);
    errno = saved;
    return false;
  }
  return db_fsync_parent_directory(path);
}

static bool db_persist_mode(const db_config *config, db_mode mode) {
  char value[8];
  snprintf(value, sizeof(value), "%s\n", db_mode_name(mode));
  return db_atomic_write(config->mode_path, value, 0600);
}

static bool db_load_or_initialize_mode(db_config *config) {
  struct stat metadata;
  char value[9];
  ssize_t length;
  int descriptor;
  db_mode loaded;
  if (lstat(config->mode_path, &metadata) != 0) {
    if (errno != ENOENT) return false;
    return db_persist_mode(config, config->mode);
  }
  if (!S_ISREG(metadata.st_mode) || S_ISLNK(metadata.st_mode) ||
      metadata.st_uid != geteuid() || (metadata.st_mode & 07777) != 0600) {
    errno = EPERM;
    return false;
  }
  descriptor = open(config->mode_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) return false;
  length = read(descriptor, value, sizeof(value) - 1);
  if (close(descriptor) != 0 || length <= 0 || length >= (ssize_t)sizeof(value))
    return false;
  value[length] = '\0';
  if (value[length - 1] == '\n') value[--length] = '\0';
  if (length <= 0 || !db_parse_mode(value, &loaded)) {
    errno = EINVAL;
    return false;
  }
  config->mode = loaded;
  return true;
}

static bool db_apply_mode(db_state *state, db_mode mode, uint64_t now) {
  if (!db_persist_mode(&state->config, mode)) return false;
  state->config.mode = mode;
  state->maintenance_deadline_ms = 0;
  if (mode == DB_MODE_OFF) {
    state->terminating_pid = 0;
    state->armed = false;
    state->waiting_start = false;
    state->next_restart_ms = 0;
  } else {
    state->armed = true;
    if (state->app_pid == 0 && !state->waiting_start) state->next_restart_ms = now;
  }
  state->last_reason = "mode_changed";
  state->status_dirty = true;
  return true;
}

static size_t db_recent_failure_count(db_state *state, uint64_t now) {
  size_t input;
  size_t output = 0;
  for (input = 0; input < state->failure_count; ++input) {
    if (now - state->failures[input] <= DB_CRASH_WINDOW_MS)
      state->failures[output++] = state->failures[input];
  }
  state->failure_count = output;
  return output;
}

static const char *db_supervision_state(const db_state *state, uint64_t now) {
  if (state->stopping) return "stopped";
  if (state->disabled_by_file) return "disabled_by_file";
  if (state->config.mode == DB_MODE_OFF) return "off";
  if (!state->armed) return "waiting_heartbeat";
  if (state->maintenance_deadline_ms > now) return "maintenance";
  if (state->waiting_start) return "waiting_start";
  if (state->app_pid > 0) return "healthy";
  if (state->launch_inhibited) return "launch_inhibited";
  if (db_presence_gate_enabled(state) && state->presence_present)
    return "launch_pending_no_heartbeat";
  if (now < state->boot_grace_deadline_ms) return "boot_grace";
  if (db_presence_gate_enabled(state) && !state->ui_ready) return "waiting_springboard";
  if (state->next_restart_ms > now) return "restart_backoff";
  return "launch_pending";
}

static int db_render_status(db_state *state, uint64_t now, char *output,
                            size_t capacity) {
  uint64_t heartbeat_age = state->last_heartbeat_ms == 0
                               ? 0
                               : now - state->last_heartbeat_ms;
  uint64_t restart_remaining = state->next_restart_ms > now
                                   ? (state->next_restart_ms - now + 999) / 1000
                                   : 0;
  uint64_t maintenance_remaining = state->maintenance_deadline_ms > now
                                       ? (state->maintenance_deadline_ms - now + 999) / 1000
                                       : 0;
  return snprintf(
      output, capacity,
      "{\"schema_version\":1,\"mode\":\"%s\",\"state\":\"%s\","
      "\"armed\":%s,\"safe_mode\":%s,\"app_pid\":%ld,"
      "\"heartbeat_age_ms\":%llu,\"restart_count_5m\":%lu,"
      "\"next_restart_seconds\":%llu,\"maintenance_remaining_seconds\":%llu,"
      "\"peer_credentials\":\"%s\",\"last_reason\":\"%s\","
      "\"configured_mode\":\"%s\",\"disabled_by_file\":%s,"
      "\"launch_inhibited\":%s,\"ui_ready\":%s,\"app_process_present\":%s,"
      "\"activation_nudges\":%u}\n",
      state->disabled_by_file ? "off" : db_mode_name(state->config.mode),
      db_supervision_state(state, now),
      state->armed && !state->disabled_by_file ? "true" : "false",
      state->safe_mode ? "true" : "false",
      (long)state->app_pid, (unsigned long long)heartbeat_age,
      (unsigned long)db_recent_failure_count(state, now),
      (unsigned long long)restart_remaining,
      (unsigned long long)maintenance_remaining,
      state->peer_credentials_enforced ? "enforced" : "socket_permissions",
      state->last_reason == NULL ? "none" : state->last_reason,
      db_mode_name(state->config.mode),
      state->disabled_by_file ? "true" : "false",
      state->launch_inhibited ? "true" : "false",
      !db_presence_gate_enabled(state) || state->ui_ready ? "true" : "false",
      state->presence_present ? "true" : "false",
      state->activation_nudges);
}

static bool db_write_status(db_state *state, uint64_t now) {
  char status[DB_STATUS_MAX];
  int length = db_render_status(state, now, status, sizeof(status));
  if (length < 0 || (size_t)length >= sizeof(status)) return false;
  if (!db_atomic_write(state->config.status_path, status, 0644)) return false;
  state->status_dirty = false;
  return true;
}

static bool db_write_safe_mode_marker(db_state *state) {
  const char marker[] =
      "{\"schema_version\":1,\"safe_mode\":true,"
      "\"reason\":\"crash_loop_3_in_5m\"}\n";
  return db_atomic_write(state->config.marker_path, marker, 0644);
}

static uint64_t db_scaled_ms(const db_state *state, uint64_t milliseconds) {
  double scaled = (double)milliseconds * state->config.time_scale;
  return scaled < 1.0 ? 1 : (uint64_t)scaled;
}

static uint64_t db_scaled_delay(const db_state *state, uint64_t seconds) {
  return db_scaled_ms(state, seconds * 1000ULL);
}

static void db_set_reason(db_state *state, const char *reason) {
  if (state->last_reason == reason) return;
  state->last_reason = reason;
  state->status_dirty = true;
}

/* The presence gate exists only for the profile whose launcher is fire-and-forget
   (`uiopen`). Android's `startservice` reports its own failure, so it is unchanged. */
static bool db_presence_gate_enabled(const db_state *state) {
  if (state->config.profile == DB_PROFILE_IOS5) return true;
#ifdef DB_KEEPALIVE_TESTING
  if (state->config.profile == DB_PROFILE_TEST &&
      state->config.test_process_file != NULL) return true;
#endif
  return false;
}

#ifdef DB_KEEPALIVE_TESTING
/* Testing-only seam: a fixed file of `NAME PID` lines stands in for the kernel
   process table so the cold-boot and no-heartbeat paths are host-testable. The
   production binary is compiled without it and has no equivalent option. */
static void db_scan_test_process_file(const db_config *config, bool *ui_present,
                                      bool *app_present) {
  char buffer[4096];
  char *line;
  char *save;
  ssize_t length;
  int descriptor;
  *ui_present = false;
  *app_present = false;
  descriptor = open(config->test_process_file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) return;
  length = read(descriptor, buffer, sizeof(buffer) - 1);
  close(descriptor);
  if (length <= 0) return;
  buffer[length] = '\0';
  for (line = strtok_r(buffer, "\n", &save); line != NULL;
       line = strtok_r(NULL, "\n", &save)) {
    char name[64];
    long pid = 0;
    if (sscanf(line, "%63s %ld", name, &pid) < 1) continue;
    if (pid > 0 && (!db_pid_alive((pid_t)pid) ||
                    !db_pid_uid_matches((pid_t)pid, config->app_uid))) continue;
    if (strcmp(name, DB_UI_PROCESS_NAME) == 0) *ui_present = true;
    if (strcmp(name, DB_APP_PROCESS_NAME) == 0) *app_present = true;
  }
}
#endif

static void db_refresh_presence(db_state *state, uint64_t now) {
  bool ui_present = false;
  bool app_present = false;
  if (!db_presence_gate_enabled(state)) {
    state->ui_ready = true;
    state->presence_present = false;
    state->presence_valid = true;
    return;
  }
  if (state->presence_valid &&
      now - state->presence_checked_ms < db_scaled_ms(state, DB_PRESENCE_SCAN_MS))
    return;
#ifdef DB_KEEPALIVE_TESTING
  if (state->config.test_process_file != NULL)
    db_scan_test_process_file(&state->config, &ui_present, &app_present);
  else
#endif
    db_scan_process_table(DB_UI_PROCESS_NAME, DB_APP_PROCESS_NAME,
                          state->config.app_uid, &ui_present, &app_present);
  state->ui_ready = ui_present;
  state->presence_present = app_present;
  state->presence_valid = true;
  state->presence_checked_ms = now;
}

/* A root-owned kill switch that survives every control path: while the file
   exists the helper never launches and reports mode `off`, without rewriting the
   persisted administrator mode. */
static bool db_disable_file_present(const db_state *state) {
  struct stat metadata;
  if (state->config.disable_path == NULL) return false;
  if (lstat(state->config.disable_path, &metadata) != 0) return false;
  if (!S_ISREG(metadata.st_mode) || S_ISLNK(metadata.st_mode)) return false;
  return metadata.st_uid == 0 || metadata.st_uid == geteuid();
}

static void db_record_failure(db_state *state, const char *reason, uint64_t now) {
  static const uint64_t backoff_seconds[] = {2, 5, 10, 30, 60};
  uint64_t delay;
  if (db_recent_failure_count(state, now) == 0 && !state->safe_mode)
    state->backoff_index = 0;
  if (state->failure_count == DB_FAILURE_MAX) {
    memmove(state->failures, state->failures + 1,
            (DB_FAILURE_MAX - 1) * sizeof(state->failures[0]));
    state->failure_count--;
  }
  state->failures[state->failure_count++] = now;
  if (state->failure_count >= 3 && !state->safe_mode) {
    state->safe_mode = true;
    if (!db_write_safe_mode_marker(state))
      db_log("doorbell-keepalive: safe-mode marker write failed: %s\n",
             strerror(errno));
  }
  if (state->backoff_index >= sizeof(backoff_seconds) / sizeof(backoff_seconds[0]))
    state->backoff_index = sizeof(backoff_seconds) / sizeof(backoff_seconds[0]) - 1;
  delay = db_scaled_delay(state, backoff_seconds[state->backoff_index]);
  if (state->backoff_index + 1 < sizeof(backoff_seconds) / sizeof(backoff_seconds[0]))
    state->backoff_index++;
  state->next_restart_ms = now + delay;
  state->waiting_start = false;
  state->app_pid = 0;
  state->last_heartbeat_ms = 0;
  state->last_sequence = 0;
  state->expected_exit = false;
  state->last_reason = reason;
  state->status_dirty = true;
  db_log("doorbell-keepalive: %s; restart scheduled after %llu ms%s\n",
         reason, (unsigned long long)delay,
         state->safe_mode ? " in safe mode" : "");
}

/* A clean stop that the operator or the app itself requested is not a crash: it
   must not consume a safe-mode failure slot or lengthen the restart backoff. */
static void db_note_expected_exit(db_state *state, const char *reason, uint64_t now) {
  state->app_pid = 0;
  state->waiting_start = false;
  state->last_heartbeat_ms = 0;
  state->last_sequence = 0;
  state->expected_exit = false;
  state->next_restart_ms = now + db_scaled_delay(state, 2);
  state->last_reason = reason;
  state->status_dirty = true;
  db_log("doorbell-keepalive: %s; no failure charged\n", reason);
}

static void db_begin_termination(db_state *state, pid_t pid, uint64_t now) {
  if (pid <= 0 || !db_pid_uid_matches(pid, state->config.app_uid)) return;
  if (kill(pid, SIGTERM) == 0 || errno == EPERM) {
    state->terminating_pid = pid;
    state->termination_deadline_ms = now + state->config.terminate_grace_ms;
  }
}

static void db_check_termination(db_state *state, uint64_t now) {
  if (state->terminating_pid <= 0) return;
  if (!db_pid_alive(state->terminating_pid)) {
    state->terminating_pid = 0;
    return;
  }
  if (now >= state->termination_deadline_ms &&
      db_pid_uid_matches(state->terminating_pid, state->config.app_uid)) {
    if (kill(state->terminating_pid, SIGKILL) == 0)
      db_log("doorbell-keepalive: terminated unresponsive app pid %ld\n",
             (long)state->terminating_pid);
    state->termination_deadline_ms = now + 250;
  }
}

static bool db_fixed_executable_allowed(const char *path) {
  struct stat metadata;
  unsigned char magic[4];
  int descriptor;
  ssize_t length;
  if (lstat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      S_ISLNK(metadata.st_mode) || (metadata.st_mode & 0111) == 0 ||
      (metadata.st_mode & 0022) != 0) return false;
#ifndef DB_KEEPALIVE_TESTING
  if (metadata.st_uid != 0) return false;
#endif
  descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) return false;
  length = read(descriptor, magic, sizeof(magic));
  close(descriptor);
  if (length != (ssize_t)sizeof(magic)) return false;
  if (magic[0] == 0x7f && magic[1] == 'E' && magic[2] == 'L' && magic[3] == 'F')
    return true;
  if ((magic[0] == 0xce && magic[1] == 0xfa && magic[2] == 0xed && magic[3] == 0xfe) ||
      (magic[0] == 0xfe && magic[1] == 0xed && magic[2] == 0xfa && magic[3] == 0xce) ||
      (magic[0] == 0xcf && magic[1] == 0xfa && magic[2] == 0xed && magic[3] == 0xfe) ||
      (magic[0] == 0xfe && magic[1] == 0xed && magic[2] == 0xfa && magic[3] == 0xcf) ||
      (magic[0] == 0xca && magic[1] == 0xfe && magic[2] == 0xba && magic[3] == 0xbe) ||
      (magic[0] == 0xbe && magic[1] == 0xba && magic[2] == 0xfe && magic[3] == 0xca))
    return true;
  return false;
}

static bool db_launch_app(db_state *state, uint64_t now) {
  static char *const ios_argv[] = {
      (char *)"/usr/bin/uiopen", (char *)"doorbell://", NULL};
  static char *const android_argv[] = {
      (char *)"/system/bin/app_process", (char *)"/system/bin",
      (char *)"com.android.commands.am.Am", (char *)"startservice",
      (char *)"--user", (char *)"0", (char *)"-n",
      (char *)"jp.ox.doorbell/.DoorbellService", NULL};
  char *const *arguments = NULL;
  const char *executable = NULL;
  bool drop_identity = false;
  pid_t child;
  if (state->terminating_pid > 0 && db_pid_alive(state->terminating_pid)) return false;
  if (state->config.profile == DB_PROFILE_IOS5) {
    executable = ios_argv[0];
    arguments = ios_argv;
    drop_identity = true;
  } else if (state->config.profile == DB_PROFILE_ANDROID) {
    executable = android_argv[0];
    arguments = android_argv;
#ifdef DB_KEEPALIVE_TESTING
  } else if (state->config.profile == DB_PROFILE_TEST) {
    static char *test_argv[2];
    test_argv[0] = (char *)state->config.test_exec;
    test_argv[1] = NULL;
    executable = test_argv[0];
    arguments = test_argv;
#endif
  }
  if (executable == NULL || arguments == NULL) return false;
  if (!db_fixed_executable_allowed(executable)) {
    db_record_failure(state, "fixed_launcher_rejected", now);
    return false;
  }
  if (state->safe_mode &&
      state->safe_mode_launches >= state->config.safe_mode_launch_cap) {
    if (!state->launch_inhibited) {
      state->launch_inhibited = true;
      db_log("doorbell-keepalive: safe-mode launch cap %u reached; launching stopped "
             "until the safe-mode marker is cleared\n",
             state->config.safe_mode_launch_cap);
    }
    db_set_reason(state, "launch_inhibited");
    return false;
  }
  child = fork();
  if (child < 0) {
    db_record_failure(state, "fork_failed", now);
    return false;
  }
  if (child == 0) {
    if (state->safe_mode) setenv("DOORBELL_SAFE_MODE", "1", 1);
    else unsetenv("DOORBELL_SAFE_MODE");
    if (state->config.profile == DB_PROFILE_ANDROID)
      setenv("CLASSPATH", "/system/framework/am.jar", 1);
    if (drop_identity) {
      /* The launcher runs as the installed application identity. The primary group
         is the configured socket GID so the child can reach the 0660 socket. */
      gid_t child_gid = state->config.socket_gid_set
                            ? state->config.socket_gid
                            : (gid_t)state->config.app_uid;
      if (setgroups(0, NULL) != 0 || setgid(child_gid) != 0 ||
          setuid(state->config.app_uid) != 0) _exit(126);
    }
    execv(executable, arguments);
    _exit(127);
  }
  state->launcher_pid = child;
  state->waiting_start = true;
  state->startup_deadline_ms = now + state->config.startup_timeout_ms;
  state->next_restart_ms = 0;
  if (state->safe_mode) state->safe_mode_launches++;
  state->last_reason = state->safe_mode ? "safe_mode_launch" : "launch";
  state->status_dirty = true;
  db_log("doorbell-keepalive: launched fixed %s profile\n",
         state->config.profile == DB_PROFILE_IOS5
             ? "ios5"
             : state->config.profile == DB_PROFILE_ANDROID ? "android" : "test");
  return true;
}

/* iOS 5 starts a fresh process from `uiopen` without activating it: Core comes up
   and listens, but SpringBoard leaves the app in the background (or behind the
   post-boot lock screen), so no heartbeat ever arrives and the screen stays on the
   launcher. A second `uiopen` against the running process activates it (observed
   on iPad 1, iOS 5.1.1). While a present app stays silent, re-run the fixed
   launcher on a bounded interval. This is a nudge, not a launch: it charges no
   failure, arms no backoff, counts against no cap, and stops on the first
   heartbeat. After a boot it also brings the app to the front as soon as the
   operator unlocks the device. */
static void db_activate_app(db_state *state, uint64_t now) {
  static char *const ios_argv[] = {
      (char *)"/usr/bin/uiopen", (char *)"doorbell://", NULL};
  char *const *arguments = NULL;
  const char *executable = NULL;
  bool drop_identity = false;
  uint64_t interval;
  pid_t child;
  if (state->config.activate_interval_ms == 0) return;
  if (!db_presence_gate_enabled(state) || !state->ui_ready) return;
  if (state->launch_inhibited || state->stopping) return;
  if (state->next_activate_ms != 0 && now < state->next_activate_ms) return;
  if (state->nudge_pid > 0 && db_pid_alive(state->nudge_pid)) return;
  /* In safe mode a nudge is what fronts an app that iOS itself keeps relaunching
     (voip background mode), so it must obey the backoff ladder and the absolute
     cap exactly like a launch; otherwise a crash loop is re-fronted every interval
     forever and `launch_inhibited` can never be reached on such a device. */
  if (state->safe_mode) {
    if (state->next_restart_ms != 0 && now < state->next_restart_ms) return;
    if (state->safe_mode_launches >= state->config.safe_mode_launch_cap) {
      if (!state->launch_inhibited) {
        state->launch_inhibited = true;
        state->status_dirty = true;
        db_log("doorbell-keepalive: safe-mode launch cap %u reached by activation "
               "nudges; launching and nudging stopped until the safe-mode marker "
               "is cleared\n",
               state->config.safe_mode_launch_cap);
      }
      db_set_reason(state, "launch_inhibited");
      return;
    }
  }
  if (state->config.profile == DB_PROFILE_IOS5) {
    executable = ios_argv[0];
    arguments = ios_argv;
    drop_identity = true;
#ifdef DB_KEEPALIVE_TESTING
  } else if (state->config.profile == DB_PROFILE_TEST) {
    static char *test_argv[2];
    test_argv[0] = (char *)state->config.test_exec;
    test_argv[1] = NULL;
    executable = test_argv[0];
    arguments = test_argv;
#endif
  }
  if (executable == NULL || arguments == NULL) return;
  if (!db_fixed_executable_allowed(executable)) return;
  interval = (uint64_t)((double)state->config.activate_interval_ms * state->config.time_scale);
  if (interval == 0) interval = 1;
  state->next_activate_ms = now + interval;
  child = fork();
  if (child < 0) return;
  if (child == 0) {
    setenv("DOORBELL_ACTIVATE", "1", 1);
    if (state->safe_mode) setenv("DOORBELL_SAFE_MODE", "1", 1);
    else unsetenv("DOORBELL_SAFE_MODE");
    if (drop_identity) {
      gid_t child_gid = state->config.socket_gid_set
                            ? state->config.socket_gid
                            : (gid_t)state->config.app_uid;
      if (setgroups(0, NULL) != 0 || setgid(child_gid) != 0 ||
          setuid(state->config.app_uid) != 0) _exit(126);
    }
    execv(executable, arguments);
    _exit(127);
  }
  state->nudge_pid = child;
  state->activation_nudges++;
  if (state->safe_mode) state->safe_mode_launches++;
  state->status_dirty = true;
  db_log("doorbell-keepalive: activation nudge %u for a present app without heartbeat\n",
         state->activation_nudges);
}

/* The launcher is fire-and-forget on iOS 5, so its exit status is the only direct
   evidence that `uiopen` reached SpringBoard. Discarding it turned every failed
   launch into an indistinguishable 30-second startup timeout. */
static void db_reap_children(db_state *state, uint64_t now) {
  int status;
  pid_t child;
  while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
    if (child == state->nudge_pid) {
      /* Activation nudges are advisory: their exit status is never a failure. */
      state->nudge_pid = 0;
      continue;
    }
    if (child != state->launcher_pid) continue;
    state->launcher_pid = 0;
    if (!state->waiting_start) continue;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) continue;
    if (WIFEXITED(status))
      db_log("doorbell-keepalive: launcher exited with status %d\n",
             WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
      db_log("doorbell-keepalive: launcher killed by signal %d\n", WTERMSIG(status));
    db_record_failure(state, "launcher_failed", now);
  }
}

static bool db_create_socket(db_state *state) {
  struct sockaddr_un address;
  struct stat existing;
  mode_t previous_umask;
  int descriptor;
  if (lstat(state->config.socket_path, &existing) == 0) {
    if (!S_ISSOCK(existing.st_mode) || S_ISLNK(existing.st_mode)) {
      errno = EEXIST;
      return false;
    }
    if (unlink(state->config.socket_path) != 0) return false;
  } else if (errno != ENOENT) {
    return false;
  }
  bool stream_transport = state->config.profile == DB_PROFILE_ANDROID;
#ifdef DB_KEEPALIVE_TESTING
  if (state->config.profile == DB_PROFILE_TEST && state->config.test_stream)
    stream_transport = true;
#endif
  descriptor = socket(AF_UNIX, stream_transport ? SOCK_STREAM : SOCK_DGRAM, 0);
  if (descriptor < 0) return false;
  if (fcntl(descriptor, F_SETFL, O_NONBLOCK) != 0 ||
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
    close(descriptor);
    return false;
  }
#ifdef __linux__
  if (!stream_transport) {
    int enabled = 1;
    if (setsockopt(descriptor, SOL_SOCKET, SO_PASSCRED, &enabled, sizeof(enabled)) != 0) {
      close(descriptor);
      return false;
    }
  }
  state->peer_credentials_enforced = true;
#endif
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
#ifdef __APPLE__
  address.sun_len = sizeof(address);
#endif
  snprintf(address.sun_path, sizeof(address.sun_path), "%s", state->config.socket_path);
  previous_umask = umask(0117);
  if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
    int saved = errno;
    umask(previous_umask);
    close(descriptor);
    errno = saved;
    return false;
  }
  umask(previous_umask);
  if (chmod(state->config.socket_path, 0660) != 0 ||
      (state->config.socket_gid_set &&
       chown(state->config.socket_path, (uid_t)-1, state->config.socket_gid) != 0)) {
    int saved = errno;
    close(descriptor);
    unlink(state->config.socket_path);
    errno = saved;
    return false;
  }
  if (stream_transport && listen(descriptor, 4) != 0) {
    int saved = errno;
    close(descriptor);
    unlink(state->config.socket_path);
    errno = saved;
    return false;
  }
  state->socket_fd = descriptor;
  return true;
}

static bool db_sender_allowed(const db_state *state, uid_t sender_uid, bool has_uid) {
  if (!state->peer_credentials_enforced) return true;
  return has_uid && (sender_uid == 0 || sender_uid == state->config.app_uid);
}

static bool db_stream_transport(const db_state *state) {
  if (state->config.profile == DB_PROFILE_ANDROID) return true;
#ifdef DB_KEEPALIVE_TESTING
  if (state->config.profile == DB_PROFILE_TEST && state->config.test_stream) return true;
#endif
  return false;
}

static void db_note_stream_heartbeat(db_state *state, pid_t pid, uint64_t sequence,
                                     uint64_t now) {
  if (pid <= 0 || !db_pid_uid_matches(pid, state->config.app_uid)) return;
  if (state->app_pid == pid && sequence <= state->last_sequence) return;
  state->app_pid = pid;
  state->last_sequence = sequence;
  state->last_heartbeat_ms = now;
  state->waiting_start = false;
  state->next_restart_ms = 0;
  state->expected_exit = false;
  /* A heartbeat inside an active lease must not revoke the grace: the operator may
     still kill the app before the lease ends, and that exit is maintenance, not a crash. */
  if (state->maintenance_deadline_ms <= now) state->maintenance_exit_grace = false;
  state->presence_present = true;
  state->presence_valid = false;
  if (state->terminating_pid == pid) state->terminating_pid = 0;
  if (state->config.mode == DB_MODE_AUTO) state->armed = true;
  state->last_reason = "heartbeat";
  state->status_dirty = true;
}

static void db_write_stream_reply(int descriptor, const db_state *state,
                                  const char *error) {
  char response[512];
  bool enabled = state->config.mode != DB_MODE_OFF && state->armed;
  bool running = state->app_pid > 0 && db_pid_alive(state->app_pid);
  int length = snprintf(response, sizeof(response),
                        "{\"enabled\":%s,\"running\":%s,\"version\":\"1.0\","
                        "\"safe_mode\":%s,\"error\":\"%s\"}\n",
                        enabled ? "true" : "false", running ? "true" : "false",
                        state->safe_mode ? "true" : "false", error == NULL ? "" : error);
  if (length > 0 && (size_t)length < sizeof(response))
    (void)db_write_all(descriptor, response, (size_t)length);
}

static void db_handle_stream_command(db_state *state, const char *command,
                                     uid_t sender_uid, pid_t sender_pid,
                                     uint64_t now, int descriptor) {
  uint64_t value;
  const char *error = NULL;
  if (strcmp(command, "STATUS") == 0) {
    db_write_stream_reply(descriptor, state, NULL);
    return;
  }
  if (strncmp(command, "MODE ", 5) == 0) {
    db_mode mode;
    if (!db_parse_mode(command + 5, &mode)) error = "invalid_mode";
    else if (!db_apply_mode(state, mode, now)) error = "mode_persist_failed";
  } else if (strcmp(command, "ENABLE") == 0) {
    if (state->config.mode == DB_MODE_OFF) {
      error = "mode_off";
    } else {
      state->armed = true;
      if (sender_uid == state->config.app_uid)
        db_note_stream_heartbeat(state, sender_pid, now, now);
      state->last_reason = "enabled";
      state->status_dirty = true;
    }
  } else if (strcmp(command, "DISABLE") == 0) {
    if (state->config.mode == DB_MODE_ON) {
      error = "mode_on";
    } else {
      state->armed = false;
      state->app_pid = 0;
      state->last_heartbeat_ms = 0;
      state->waiting_start = false;
      state->next_restart_ms = 0;
      state->last_reason = "disabled";
      state->status_dirty = true;
    }
  } else if (strncmp(command, "KICK ", 5) == 0 &&
             db_parse_u64(command + 5, &value) && value > 0) {
    if (sender_uid != state->config.app_uid) error = "app_uid_required";
    else db_note_stream_heartbeat(state, sender_pid, value, now);
  } else if (strncmp(command, "PAUSE_LEASE ", 12) == 0 &&
             db_parse_u64(command + 12, &value) && value >= 1 &&
             value <= DB_MAINTENANCE_MAX_SECONDS) {
    state->maintenance_deadline_ms = now + value * 1000ULL;
    state->terminating_pid = 0;
    state->maintenance_exit_grace = true;
    state->last_reason = "maintenance_started";
    state->status_dirty = true;
  } else {
    error = "invalid_command";
  }
  db_write_stream_reply(descriptor, state, error);
}

static void db_accept_stream(db_state *state, uint64_t now) {
  char command[513] = {0};
  size_t used = 0;
  int descriptor = accept(state->socket_fd, NULL, NULL);
  uid_t sender_uid = (uid_t)-1;
  pid_t sender_pid = 0;
  bool allowed = false;
  struct pollfd item;
  if (descriptor < 0) return;
  (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
#ifdef __linux__
  {
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 &&
        length == sizeof(credentials)) {
      sender_uid = credentials.uid;
      sender_pid = credentials.pid;
      allowed = sender_uid == 0 || sender_uid == state->config.app_uid;
    }
  }
#elif defined(__APPLE__)
  {
    uid_t effective_uid;
    gid_t effective_gid;
    if (getpeereid(descriptor, &effective_uid, &effective_gid) == 0) {
      (void)effective_gid;
      sender_uid = effective_uid;
#ifdef DB_KEEPALIVE_TESTING
      sender_pid = getppid();
#endif
      allowed = sender_uid == 0 || sender_uid == state->config.app_uid;
    }
  }
#else
  sender_uid = state->config.app_uid;
  allowed = true;
#endif
  if (!allowed) {
    close(descriptor);
    return;
  }
  item.fd = descriptor;
  item.events = POLLIN;
  item.revents = 0;
  while (used < sizeof(command) - 1 && poll(&item, 1, 500) > 0) {
    char byte;
    ssize_t count = read(descriptor, &byte, 1);
    if (count != 1) break;
    if (byte == '\n') {
      command[used] = '\0';
      db_handle_stream_command(state, command, sender_uid, sender_pid, now, descriptor);
      close(descriptor);
      return;
    }
    if ((unsigned char)byte < 0x20 || (unsigned char)byte > 0x7e) break;
    command[used++] = byte;
  }
  db_write_stream_reply(descriptor, state, "invalid_command");
  close(descriptor);
}

static void db_send_response(db_state *state, const struct sockaddr_un *peer,
                             socklen_t peer_length, const char *response) {
  if (peer_length <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
      peer->sun_path[0] == '\0') return;
  if (strlen(response) > 512) return;
  (void)sendto(state->socket_fd, response, strlen(response), 0,
               (const struct sockaddr *)peer, peer_length);
}

static void db_accept_heartbeat(db_state *state, const db_message *message,
                                uid_t sender_uid, bool has_uid, uint64_t now) {
  if (state->peer_credentials_enforced &&
      (!has_uid || sender_uid != state->config.app_uid)) return;
  if (!db_pid_uid_matches(message->pid, state->config.app_uid)) return;
  if (state->app_pid == message->pid && message->sequence <= state->last_sequence) return;
  state->app_pid = message->pid;
  state->last_sequence = message->sequence;
  state->last_heartbeat_ms = now;
  state->waiting_start = false;
  state->next_restart_ms = 0;
  /* `stopping` is the app announcing an orderly exit; the following process
     disappearance is expected and must not be charged as a crash. */
  state->expected_exit = message->event == DB_EVENT_STOPPING;
  if (state->maintenance_deadline_ms <= now) state->maintenance_exit_grace = false;
  state->presence_present = true;
  state->presence_valid = false;
  if (state->terminating_pid == message->pid) state->terminating_pid = 0;
  if (state->config.mode == DB_MODE_AUTO) state->armed = true;
  state->last_reason = message->event == DB_EVENT_MEMORY_PRESSURE
                           ? "memory_pressure"
                           : message->event == DB_EVENT_STOPPING ? "stopping" : "heartbeat";
  state->status_dirty = true;
}

static bool db_parse_lease(const char *data, size_t length, uint64_t *seconds) {
  static const char prefix[] = "MAINTENANCE_BEGIN ";
  char number[24];
  size_t number_length;
  if (length <= sizeof(prefix) - 1 ||
      memcmp(data, prefix, sizeof(prefix) - 1) != 0) return false;
  number_length = length - (sizeof(prefix) - 1);
  if (number_length >= sizeof(number)) return false;
  memcpy(number, data + sizeof(prefix) - 1, number_length);
  number[number_length] = '\0';
  if (!db_parse_u64(number, seconds)) return false;
  return *seconds >= 1 && *seconds <= DB_MAINTENANCE_MAX_SECONDS;
}

static void db_handle_datagram(db_state *state, uint64_t now) {
  char data[DB_PROTOCOL_MAX + 1];
  char control_response[DB_STATUS_MAX];
  struct sockaddr_un peer;
  struct iovec input;
  struct msghdr header;
  uid_t sender_uid = (uid_t)-1;
  bool has_uid = false;
#ifdef __linux__
  char control[CMSG_SPACE(sizeof(struct ucred))];
#endif
  ssize_t length;
  memset(&peer, 0, sizeof(peer));
  memset(&header, 0, sizeof(header));
  input.iov_base = data;
  input.iov_len = sizeof(data);
  header.msg_name = &peer;
  header.msg_namelen = sizeof(peer);
  header.msg_iov = &input;
  header.msg_iovlen = 1;
#ifdef __linux__
  header.msg_control = control;
  header.msg_controllen = sizeof(control);
#endif
  length = recvmsg(state->socket_fd, &header, 0);
  if (length < 0) return;
  if ((header.msg_flags & MSG_TRUNC) != 0 || length == 0 ||
      (size_t)length > DB_PROTOCOL_MAX) return;
#ifdef __linux__
  {
    struct cmsghdr *item;
    for (item = CMSG_FIRSTHDR(&header); item != NULL;
         item = CMSG_NXTHDR(&header, item)) {
      if (item->cmsg_level == SOL_SOCKET && item->cmsg_type == SCM_CREDENTIALS &&
          item->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
        const struct ucred *credentials =
            (const struct ucred *)CMSG_DATA(item);
        sender_uid = credentials->uid;
        has_uid = true;
        break;
      }
    }
  }
#endif
  if (!db_sender_allowed(state, sender_uid, has_uid)) return;
  data[length] = '\0';
  if ((size_t)length == strlen("STATUS") && memcmp(data, "STATUS", (size_t)length) == 0) {
    int rendered = db_render_status(state, now, control_response, sizeof(control_response));
    if (rendered > 0 && (size_t)rendered < sizeof(control_response))
      db_send_response(state, &peer, header.msg_namelen, control_response);
    return;
  }
  if ((size_t)length == strlen("MAINTENANCE_END") &&
      memcmp(data, "MAINTENANCE_END", (size_t)length) == 0) {
    state->maintenance_deadline_ms = 0;
    state->last_reason = "maintenance_ended";
    state->status_dirty = true;
    db_send_response(state, &peer, header.msg_namelen, "{\"ok\":true}\n");
    return;
  }
  if ((size_t)length == strlen("SAFE_MODE_CLEAR") &&
      memcmp(data, "SAFE_MODE_CLEAR", (size_t)length) == 0) {
    if (state->peer_credentials_enforced && has_uid && sender_uid == 0) {
      state->safe_mode = false;
      state->failure_count = 0;
      state->backoff_index = 0;
      state->safe_mode_launches = 0;
      state->launch_inhibited = false;
      unlink(state->config.marker_path);
      state->last_reason = "safe_mode_cleared";
      state->status_dirty = true;
      db_send_response(state, &peer, header.msg_namelen, "{\"ok\":true}\n");
    } else {
      db_send_response(state, &peer, header.msg_namelen,
                       "{\"ok\":false,\"error\":\"root_required\"}\n");
    }
    return;
  }
  if ((size_t)length > strlen("MODE ") &&
      memcmp(data, "MODE ", strlen("MODE ")) == 0) {
    db_mode mode;
    if (!db_parse_mode(data + strlen("MODE "), &mode)) {
      db_send_response(state, &peer, header.msg_namelen,
                       "{\"ok\":false,\"error\":\"invalid_mode\"}\n");
    } else if (!db_apply_mode(state, mode, now)) {
      db_send_response(state, &peer, header.msg_namelen,
                       "{\"ok\":false,\"error\":\"mode_persist_failed\"}\n");
    } else {
      db_send_response(state, &peer, header.msg_namelen, "{\"ok\":true}\n");
    }
    return;
  }
  {
    uint64_t lease_seconds;
    if (db_parse_lease(data, (size_t)length, &lease_seconds)) {
      state->maintenance_deadline_ms = now + lease_seconds * 1000ULL;
      state->terminating_pid = 0;
      /* An upgrade under the helper kills the app on purpose; the exit that
         follows a lease must not be charged as a crash. */
      state->maintenance_exit_grace = true;
      state->last_reason = "maintenance_started";
      state->status_dirty = true;
      db_send_response(state, &peer, header.msg_namelen, "{\"ok\":true}\n");
      return;
    }
  }
  {
    db_message message;
    if (db_parse_message(data, (size_t)length, &message))
      db_accept_heartbeat(state, &message, sender_uid, has_uid, now);
  }
}

static void db_supervise(db_state *state, uint64_t now) {
  bool disabled;
  db_reap_children(state, now);
  db_check_termination(state, now);
  disabled = db_disable_file_present(state);
  if (disabled != state->disabled_by_file) {
    state->disabled_by_file = disabled;
    state->status_dirty = true;
    db_set_reason(state, disabled ? "disable_file_present" : "disable_file_removed");
    db_log("doorbell-keepalive: kill switch %s at %s\n",
           disabled ? "engaged" : "released",
           state->config.disable_path == NULL ? "(unset)" : state->config.disable_path);
  }
  if (state->maintenance_deadline_ms != 0 && state->maintenance_deadline_ms <= now) {
    state->maintenance_deadline_ms = 0;
    state->last_reason = "maintenance_expired";
    state->status_dirty = true;
  }
  /* Apple datagram sockets expose no per-message credentials, so SAFE_MODE_CLEAR is
     unavailable there. Removing the marker is equivalent and already root-only: it
     lives in a root-owned directory the app UID cannot write. */
  if (state->safe_mode) {
    struct stat marker;
    if (lstat(state->config.marker_path, &marker) != 0 && errno == ENOENT) {
      state->safe_mode = false;
      state->failure_count = 0;
      state->backoff_index = 0;
      state->safe_mode_launches = 0;
      state->launch_inhibited = false;
      state->next_restart_ms = 0;
      state->last_reason = "safe_mode_cleared";
      state->status_dirty = true;
      db_log("doorbell-keepalive: safe mode cleared by marker removal\n");
    }
  }
  if (state->disabled_by_file) return;
  if (state->config.mode == DB_MODE_OFF || !state->armed ||
      state->maintenance_deadline_ms > now) return;
  if (state->app_pid > 0 && !db_pid_alive(state->app_pid)) {
    if (state->expected_exit || state->maintenance_exit_grace)
      db_note_expected_exit(state,
                            state->expected_exit ? "clean_exit" : "maintenance_exit", now);
    else
      db_record_failure(state, "process_exited", now);
    return;
  }
  if (state->app_pid > 0 && state->last_heartbeat_ms > 0 &&
      now - state->last_heartbeat_ms > state->config.heartbeat_timeout_ms) {
    pid_t hung_pid = state->app_pid;
    db_begin_termination(state, hung_pid, now);
    db_record_failure(state, "heartbeat_timeout", now);
    return;
  }
  /* Only scan while no heartbeat owns a PID: a live heartbeat already proves
     presence, and the process table is expensive to walk on an iPad 1. */
  if (state->app_pid == 0) db_refresh_presence(state, now);
  if (state->waiting_start && now >= state->startup_deadline_ms) {
    /* An unprovisioned or pre-heartbeat app is running but silent. Relaunching it
       every startup timeout is the bootstrap-setup deadlock; adopt it instead. */
    if (state->presence_present) {
      state->waiting_start = false;
      state->next_restart_ms = 0;
      db_set_reason(state, "launch_pending_no_heartbeat");
      db_activate_app(state, now);
      return;
    }
    db_record_failure(state, "startup_timeout", now);
    return;
  }
  if (state->app_pid == 0 && !state->waiting_start &&
      (state->next_restart_ms == 0 || now >= state->next_restart_ms)) {
    if (state->presence_present) {
      db_set_reason(state, "launch_pending_no_heartbeat");
      db_activate_app(state, now);
      return;
    }
    if (now < state->boot_grace_deadline_ms) {
      db_set_reason(state, "boot_grace");
      return;
    }
    if (db_presence_gate_enabled(state) && !state->ui_ready) {
      /* No SpringBoard yet: `uiopen` would fail silently, so defer without
         charging a failure and without arming the backoff ladder. */
      db_set_reason(state, "waiting_springboard");
      return;
    }
    db_launch_app(state, now);
  }
}

static void db_usage(const char *program) {
  fprintf(stderr,
          "usage: %s --socket PATH --status PATH --marker PATH --mode-file PATH "
          "--mode off|auto|on "
          "--profile ios5|android --app-uid UID [--socket-gid GID] "
          "[--disable-file PATH] [--log-max-bytes BYTES] [--activate-interval-ms MS]\n"
          "       %s --control begin|end|status|safe-mode-clear --socket PATH "
          "[--seconds 1..3600]\n",
          program, program);
}

static bool db_parse_arguments(int argc, char **argv, db_config *config) {
  int index;
  bool have_socket = false, have_status = false, have_marker = false, have_mode_file = false;
  bool have_mode = false, have_profile = false, have_uid = false;
  memset(config, 0, sizeof(*config));
  config->heartbeat_timeout_ms = DB_HEARTBEAT_TIMEOUT_MS;
  config->startup_timeout_ms = DB_STARTUP_TIMEOUT_MS;
  config->terminate_grace_ms = DB_TERMINATE_GRACE_MS;
  config->boot_grace_ms = DB_BOOT_GRACE_MS;
  config->activate_interval_ms = DB_ACTIVATE_INTERVAL_MS;
  config->log_max_bytes = DB_LOG_MAX_BYTES_DEFAULT;
  config->safe_mode_launch_cap = DB_SAFE_MODE_LAUNCH_CAP;
  config->time_scale = 1.0;
  for (index = 1; index < argc; ++index) {
    const char *option = argv[index];
    const char *value;
    uint64_t number;
    if (strcmp(option, "--help") == 0) return false;
    if (index + 1 >= argc) return false;
    value = argv[++index];
    if (strcmp(option, "--socket") == 0) {
      config->socket_path = value;
      have_socket = true;
    } else if (strcmp(option, "--status") == 0) {
      config->status_path = value;
      have_status = true;
    } else if (strcmp(option, "--marker") == 0) {
      config->marker_path = value;
      have_marker = true;
    } else if (strcmp(option, "--mode-file") == 0) {
      config->mode_path = value;
      have_mode_file = true;
    } else if (strcmp(option, "--mode") == 0) {
      if (!db_parse_mode(value, &config->mode)) return false;
      have_mode = true;
    } else if (strcmp(option, "--profile") == 0) {
      if (strcmp(value, "ios5") == 0) config->profile = DB_PROFILE_IOS5;
      else if (strcmp(value, "android") == 0) config->profile = DB_PROFILE_ANDROID;
#ifdef DB_KEEPALIVE_TESTING
      else if (strcmp(value, "test") == 0) config->profile = DB_PROFILE_TEST;
#endif
      else return false;
      have_profile = true;
    } else if (strcmp(option, "--app-uid") == 0) {
      if (!db_parse_u64(value, &number) || number > 2147483647ULL) return false;
      config->app_uid = (uid_t)number;
      have_uid = true;
    } else if (strcmp(option, "--socket-gid") == 0) {
      if (!db_parse_u64(value, &number) || number > 2147483647ULL) return false;
      config->socket_gid = (gid_t)number;
      config->socket_gid_set = true;
    } else if (strcmp(option, "--disable-file") == 0) {
      config->disable_path = value;
    } else if (strcmp(option, "--log-max-bytes") == 0) {
      if (!db_parse_u64(value, &config->log_max_bytes)) return false;
      if (config->log_max_bytes != 0 && config->log_max_bytes < 512) return false;
#ifdef DB_KEEPALIVE_TESTING
    } else if (strcmp(option, "--test-exec") == 0) {
      config->test_exec = value;
    } else if (strcmp(option, "--test-process-file") == 0) {
      config->test_process_file = value;
    } else if (strcmp(option, "--safe-mode-launch-cap") == 0) {
      if (!db_parse_u64(value, &number) || number == 0 || number > 1000) return false;
      config->safe_mode_launch_cap = (unsigned int)number;
    } else if (strcmp(option, "--boot-grace-ms") == 0) {
      if (!db_parse_u64(value, &config->boot_grace_ms)) return false;
    } else if (strcmp(option, "--activate-interval-ms") == 0) {
      if (!db_parse_u64(value, &config->activate_interval_ms)) return false;
    } else if (strcmp(option, "--test-stream") == 0) {
      if (strcmp(value, "yes") != 0) return false;
      config->test_stream = true;
    } else if (strcmp(option, "--heartbeat-timeout-ms") == 0) {
      if (!db_parse_u64(value, &config->heartbeat_timeout_ms) ||
          config->heartbeat_timeout_ms < 20) return false;
    } else if (strcmp(option, "--startup-timeout-ms") == 0) {
      if (!db_parse_u64(value, &config->startup_timeout_ms) ||
          config->startup_timeout_ms < 20) return false;
    } else if (strcmp(option, "--terminate-grace-ms") == 0) {
      if (!db_parse_u64(value, &config->terminate_grace_ms) ||
          config->terminate_grace_ms < 20) return false;
    } else if (strcmp(option, "--time-scale") == 0) {
      char *end = NULL;
      config->time_scale = strtod(value, &end);
      if (end == value || *end != '\0' || config->time_scale <= 0.0 ||
          config->time_scale > 1.0) return false;
#endif
    } else {
      return false;
    }
  }
  if (!have_socket || !have_status || !have_marker || !have_mode_file || !have_mode ||
      !have_profile || !have_uid) return false;
  if (!db_valid_path(config->socket_path, sizeof(((struct sockaddr_un *)0)->sun_path)) ||
      !db_valid_path(config->status_path, DB_PATH_MAX) ||
      !db_valid_path(config->marker_path, DB_PATH_MAX) ||
      !db_valid_path(config->mode_path, DB_PATH_MAX)) return false;
  if (config->disable_path != NULL &&
      !db_valid_path(config->disable_path, DB_PATH_MAX)) return false;
#ifdef DB_KEEPALIVE_TESTING
  if (config->profile == DB_PROFILE_TEST &&
      (config->test_exec == NULL || !db_valid_path(config->test_exec, DB_PATH_MAX)))
    return false;
  if (config->test_process_file != NULL &&
      !db_valid_path(config->test_process_file, DB_PATH_MAX)) return false;
#endif
  return true;
}

/* One-shot control client.
   A device maintenance script must be able to take a maintenance lease before it
   kills the app, and iOS 5 ships no UNIX-datagram command-line tool. This mode
   sends exactly one of four compiled payloads to the fixed socket and exits; no
   caller-supplied string ever reaches the socket, nothing is executed, and the
   daemon side of the process is never started. */
static int db_control_main(int argc, char **argv) {
  const char *socket_path = NULL;
  const char *action = NULL;
  uint64_t seconds = 300;
  char payload[64];
  char reply[DB_STATUS_MAX];
  char local_path[64];
  struct sockaddr_un helper_address;
  struct sockaddr_un local_address;
  struct pollfd item;
  ssize_t length;
  int descriptor;
  int index;
  int result = 3;
  for (index = 1; index < argc; ++index) {
    const char *option = argv[index];
    if (index + 1 >= argc) { db_usage(argv[0]); return 2; }
    if (strcmp(option, "--control") == 0) {
      action = argv[++index];
    } else if (strcmp(option, "--socket") == 0) {
      socket_path = argv[++index];
    } else if (strcmp(option, "--seconds") == 0) {
      if (!db_parse_u64(argv[++index], &seconds) || seconds < 1 ||
          seconds > DB_MAINTENANCE_MAX_SECONDS) { db_usage(argv[0]); return 2; }
    } else {
      db_usage(argv[0]);
      return 2;
    }
  }
  if (action == NULL || socket_path == NULL ||
      !db_valid_path(socket_path, sizeof(helper_address.sun_path))) {
    db_usage(argv[0]);
    return 2;
  }
  if (strcmp(action, "begin") == 0)
    snprintf(payload, sizeof(payload), "MAINTENANCE_BEGIN %llu",
             (unsigned long long)seconds);
  else if (strcmp(action, "end") == 0)
    snprintf(payload, sizeof(payload), "MAINTENANCE_END");
  else if (strcmp(action, "status") == 0)
    snprintf(payload, sizeof(payload), "STATUS");
  else if (strcmp(action, "safe-mode-clear") == 0)
    snprintf(payload, sizeof(payload), "SAFE_MODE_CLEAR");
  else {
    db_usage(argv[0]);
    return 2;
  }
  descriptor = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (descriptor < 0) {
    fprintf(stderr, "doorbell-keepalive: control socket failed: %s\n", strerror(errno));
    return 3;
  }
  snprintf(local_path, sizeof(local_path), "/var/tmp/dbka-ctl-%ld.sock", (long)getpid());
  memset(&local_address, 0, sizeof(local_address));
  local_address.sun_family = AF_UNIX;
#ifdef __APPLE__
  local_address.sun_len = sizeof(local_address);
#endif
  snprintf(local_address.sun_path, sizeof(local_address.sun_path), "%s", local_path);
  unlink(local_path);
  if (bind(descriptor, (struct sockaddr *)&local_address, sizeof(local_address)) != 0) {
    fprintf(stderr, "doorbell-keepalive: control bind failed: %s\n", strerror(errno));
    close(descriptor);
    return 3;
  }
  chmod(local_path, 0600);
  memset(&helper_address, 0, sizeof(helper_address));
  helper_address.sun_family = AF_UNIX;
#ifdef __APPLE__
  helper_address.sun_len = sizeof(helper_address);
#endif
  snprintf(helper_address.sun_path, sizeof(helper_address.sun_path), "%s", socket_path);
  if (sendto(descriptor, payload, strlen(payload), 0,
             (struct sockaddr *)&helper_address, sizeof(helper_address)) < 0) {
    fprintf(stderr, "doorbell-keepalive: control send failed: %s\n", strerror(errno));
    close(descriptor);
    unlink(local_path);
    return 3;
  }
  item.fd = descriptor;
  item.events = POLLIN;
  item.revents = 0;
  if (poll(&item, 1, 1000) > 0 && (item.revents & POLLIN) != 0) {
    length = recv(descriptor, reply, sizeof(reply) - 1, 0);
    if (length > 0) {
      reply[length] = '\0';
      printf("%s", reply);
      if (reply[length - 1] != '\n') printf("\n");
      result = 0;
    }
  }
  if (result != 0)
    fprintf(stderr, "doorbell-keepalive: no reply from %s\n", socket_path);
  close(descriptor);
  unlink(local_path);
  return result;
}

int main(int argc, char **argv) {
  db_state state;
  struct sigaction action;
  struct stat marker;
  if (argc >= 2 && strcmp(argv[1], "--control") == 0) return db_control_main(argc, argv);
  memset(&state, 0, sizeof(state));
  state.socket_fd = -1;
  state.last_reason = "startup";
  state.status_dirty = true;
  if (!db_parse_arguments(argc, argv, &state.config)) {
    db_usage(argv[0]);
    return 2;
  }
  db_log_limit = state.config.log_max_bytes;
  if (!db_load_or_initialize_mode(&state.config)) {
    fprintf(stderr, "doorbell-keepalive: mode file rejected: %s\n", strerror(errno));
    return 1;
  }
  state.armed = state.config.mode != DB_MODE_OFF;
  if (lstat(state.config.marker_path, &marker) == 0) {
    if (!S_ISREG(marker.st_mode) || S_ISLNK(marker.st_mode)) {
      fprintf(stderr, "doorbell-keepalive: unsafe safe-mode marker\n");
      return 1;
    }
    state.safe_mode = true;
  } else if (errno != ENOENT) {
    fprintf(stderr, "doorbell-keepalive: marker inspection failed: %s\n",
            strerror(errno));
    return 1;
  }
  if (!db_create_socket(&state)) {
    fprintf(stderr, "doorbell-keepalive: socket setup failed: %s\n", strerror(errno));
    return 1;
  }
  /* launchd starts this daemon at RunAtLoad, which on a cold boot is minutes
     before SpringBoard exists. Hold the first launch for a bounded grace and then
     let the SpringBoard gate decide. */
  if (db_presence_gate_enabled(&state))
    state.boot_grace_deadline_ms = db_now_ms() + state.config.boot_grace_ms;
  if (state.config.socket_gid_set &&
      state.config.socket_gid != (gid_t)state.config.app_uid)
    db_log("doorbell-keepalive: launcher primary group %ld differs from app uid %ld\n",
           (long)state.config.socket_gid, (long)state.config.app_uid);
  memset(&action, 0, sizeof(action));
  action.sa_handler = db_on_signal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  while (!db_should_stop) {
    struct pollfd item;
    uint64_t now;
    int ready;
    item.fd = state.socket_fd;
    item.events = POLLIN;
    item.revents = 0;
    ready = poll(&item, 1, 100);
    now = db_now_ms();
    if (ready > 0 && (item.revents & POLLIN) != 0) {
      if (db_stream_transport(&state)) db_accept_stream(&state, now);
      else db_handle_datagram(&state, now);
    }
    db_supervise(&state, now);
    if (state.status_dirty && !db_write_status(&state, now))
      db_log("doorbell-keepalive: status write failed: %s\n", strerror(errno));
  }
  state.stopping = true;
  state.status_dirty = true;
  db_write_status(&state, db_now_ms());
  close(state.socket_fd);
  unlink(state.config.socket_path);
  return 0;
}
