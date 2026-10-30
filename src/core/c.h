// Everything the core takes from the operating system and the terminal
// engine, translated into the Zig module `c` by the build (see build.zig).
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <util.h>
#include <libproc.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#else
#include <pty.h>
#endif
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <ghostty/vt.h>
