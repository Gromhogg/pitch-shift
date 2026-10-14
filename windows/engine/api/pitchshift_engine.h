/* Pitch Shift sound engine: the small C interface the window app (C#) calls.
   All text is UTF-8. Functions that return text return a pointer that stays valid until the
   next call of the same function on the same thread. Functions that return int give 0 for
   "worked" and a negative number for "didn't work". */
#ifndef PITCHSHIFT_ENGINE_H
#define PITCHSHIFT_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(PS_ENGINE_BUILD)
#define PS_API __declspec(dllexport)
#else
#define PS_API __declspec(dllimport)
#endif

PS_API const char* ps_version(void);

/* Call once at start. Also puts back any app volumes left quiet by an earlier crash. */
PS_API int ps_init(void);
PS_API void ps_shutdown(void);

/* Puts back every app volume Pitch Shift lowered. Returns how many were fixed. */
PS_API int ps_restore_all(void);

/* JSON list of apps that are playing sound: [{"pid":..,"exe":..,"name":..}, ...] */
PS_API const char* ps_list_sources_json(void);
/* JSON list of microphones: [{"id":..,"name":..,"default":true}, ...] */
PS_API const char* ps_list_mics_json(void);
/* JSON with what the engine is doing right now. */
PS_API const char* ps_status_json(void);

#ifdef __cplusplus
}
#endif

#endif
