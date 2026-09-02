#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
  const char *path = getenv("DB_KEEPALIVE_TEST_LOG");
  const char *safe_mode = getenv("DOORBELL_SAFE_MODE");
  const char *line = safe_mode != NULL && strcmp(safe_mode, "1") == 0
                         ? "safe=1\n"
                         : "safe=0\n";
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
