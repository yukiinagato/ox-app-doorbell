#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
  const char *path = getenv("DB_KEEPALIVE_TEST_LOG");
  const char *safe_mode = getenv("DOORBELL_SAFE_MODE");
  const char *activate = getenv("DOORBELL_ACTIVATE");
  int safe = safe_mode != NULL && strcmp(safe_mode, "1") == 0;
  int nudge = activate != NULL && strcmp(activate, "1") == 0;
  const char *line = nudge ? (safe ? "safe=1 activate=1\n" : "safe=0 activate=1\n")
                           : (safe ? "safe=1 activate=0\n" : "safe=0 activate=0\n");
  int descriptor;
  if (path == NULL) return 2;
  descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (descriptor < 0) return 3;
  if (write(descriptor, line, strlen(line)) != (ssize_t)strlen(line)) {
    close(descriptor);
    return 4;
  }
  return close(descriptor) == 0 ? 0 : 5;
}
