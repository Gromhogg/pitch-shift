using System.Runtime.InteropServices;

namespace PitchShift;

// Calls into the sound engine (PitchShiftEngine.dll, written in C++). See engine/api/pitchshift_engine.h.
static class Engine
{
    const string Dll = "PitchShiftEngine.dll";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_version();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int ps_init();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void ps_shutdown();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int ps_restore_all();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_list_sources_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_list_mics_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_status_json();

    static string Text(IntPtr p) => Marshal.PtrToStringUTF8(p) ?? "";

    public static string Version
    {
        get
        {
            try { return Text(ps_version()); }
            catch (DllNotFoundException) { return "missing"; }
        }
    }

    public static string SourcesJson() => Text(ps_list_sources_json());
    public static string MicsJson() => Text(ps_list_mics_json());
    public static string StatusJson() => Text(ps_status_json());
}
