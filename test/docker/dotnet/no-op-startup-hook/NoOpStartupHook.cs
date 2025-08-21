using System;

// A simple .NET startup hook that only sets an environment variable, so that an application under test can verify
// whether this hook has been loaded or not.
internal class StartupHook
{
    public static void Initialize()
    {
       System.Environment.SetEnvironmentVariable("otel_injector_dotnet_no_op_startup_hook_has_been_loaded", "true");
    }
}