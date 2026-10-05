using System;
using System.IO;

namespace BatteryGuard {
    public static class SourceRootConfiguration {
        public static string Resolve(string installationDirectory) {
            string configured = File.ReadAllText(Path.Combine(installationDirectory, "source-root.txt")).Trim();
            if (String.IsNullOrEmpty(configured) || !Path.IsPathRooted(configured) || configured.StartsWith("\\"))
                throw new InvalidDataException("source-root.txt must contain an absolute local clone path");
            string root = Path.GetFullPath(configured);
            if (!Directory.Exists(Path.Combine(root, "agent")))
                throw new DirectoryNotFoundException("BatteryGuard source directory is unavailable: " + root);
            return root;
        }
    }
}
