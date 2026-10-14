// C pieces the Swift code uses: Rubber Band (pitch shifting) and process info (to group helper processes under their app).
#include <rubberband/rubberband-c.h>
#include <libproc.h>
#include <sys/proc_info.h>

// Which app "owns" a helper process (for example Safari for its sound process). Part of macOS, not in public headers.
pid_t responsibility_get_pid_responsible_for_pid(pid_t);
