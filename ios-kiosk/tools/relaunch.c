#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char *end = NULL;
  long delay = strtol(argv[1], &end, 10);
  if (!end || *end || delay < 0 || delay > 300) return 2;
  sleep((unsigned int)delay);
  for (int attempt = 0; attempt < 3; ++attempt) {
    pid_t child;
    char *const args[] = {"/usr/bin/uiopen", "doorbell://", NULL};
    int status = posix_spawn(&child, args[0], NULL, NULL, args, environ);
    if (status == 0) {
      while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    for (int tick = 0; tick < 25; ++tick) {
      sleep(1);
      if (access("/var/mobile/Documents/.doorbell-relaunch-ready", F_OK) == 0) return 0;
    }
  }
  return 1;
}
