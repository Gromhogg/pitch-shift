// C pieces the Swift code uses: Rubber Band (pitch shifting), the sound ring and the Advanced processing engine,
// and process info (to group helper processes under their app).
#include <rubberband/rubberband-c.h>
#include "AudioRing.h"
#include "Advanced/AdvancedChain.h"
#include <libproc.h>
#include <sys/proc_info.h>

// Which app "owns" a helper process (for example Safari for its sound process). Part of macOS, not in public headers.
pid_t responsibility_get_pid_responsible_for_pid(pid_t);
