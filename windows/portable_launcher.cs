using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

// One-file Windows distribution. The embedded Flutter bundle is unpacked once
// per build; application data stays in Muzika's normal support directory.
internal static class MuzikaPortableLauncher
{
    [STAThread]
    private static void Main()
    {
        try
        {
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("MuzikaBundle.zip"))
            {
                if (payload == null) throw new InvalidOperationException("The Muzika package is missing.");
                string build;
                using (SHA256 hash = SHA256.Create())
                    build = BitConverter.ToString(hash.ComputeHash(payload)).Replace("-", "").Substring(0, 16);
                payload.Position = 0;
                string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Muzika", "app-" + build);
                string executable = Path.Combine(directory, "Muzika.exe");
                string ready = Path.Combine(directory, ".bundle-ready");
                using (Mutex mutex = new Mutex(false, "Local\\Muzika-Unpack-" + build))
                {
                    bool owned = false;
                    try
                    {
                        try { owned = mutex.WaitOne(TimeSpan.FromSeconds(60)); }
                        catch (AbandonedMutexException) { owned = true; }
                        if (!owned) throw new IOException("Muzika is preparing its files. Please try opening it again shortly.");
                        if (!File.Exists(ready) || !File.Exists(executable))
                        {
                            Directory.CreateDirectory(directory);
                            string root = Path.GetFullPath(directory) + Path.DirectorySeparatorChar;
                            using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read, true))
                            {
                                foreach (ZipArchiveEntry entry in archive.Entries)
                                {
                                    string target = Path.GetFullPath(Path.Combine(directory, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                                        throw new IOException("Invalid Muzika package entry.");
                                    if (entry.Name.Length == 0 || entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\")) { Directory.CreateDirectory(target); continue; }
                                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                                    using (Stream input = entry.Open())
                                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write))
                                        input.CopyTo(output);
                                }
                            }
                            File.WriteAllText(ready, build);
                        }
                    }
                    finally { if (owned) mutex.ReleaseMutex(); }
                }
                Process.Start(new ProcessStartInfo(executable) { WorkingDirectory = directory, UseShellExecute = true });
            }
        }
        catch (Exception error)
        {
            MessageBox.Show("Muzika could not open.\n\n" + error.Message, "Muzika", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
