using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;

namespace ImageUpscaleKit.Execution
{
    public sealed class IukAsyncProcessRunner : IDisposable
    {
        private readonly Process _process;
        private readonly ConcurrentQueue<string> _lines = new ConcurrentQueue<string>();
        private readonly Stopwatch _sw = new Stopwatch();
        private bool _flushed;
        private bool _disposed;

        public bool WasKilled { get; private set; }
        public int ProcessId { get; private set; }

        public IukAsyncProcessRunner(string fileName, System.Collections.IEnumerable arguments, string workingDirectory = null)
        {
            if (string.IsNullOrWhiteSpace(fileName))
                throw new ArgumentException("Executable path is required.", nameof(fileName));

            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            if (!string.IsNullOrWhiteSpace(workingDirectory))
                psi.WorkingDirectory = workingDirectory;

            if (arguments != null)
            {
                foreach (var arg in arguments)
                {
                    if (arg != null)
                        psi.ArgumentList.Add(arg.ToString());
                }
            }

            _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _process.OutputDataReceived += (sender, e) =>
            {
                if (e.Data != null)
                    _lines.Enqueue(e.Data);
            };
            _process.ErrorDataReceived += (sender, e) =>
            {
                if (e.Data != null)
                    _lines.Enqueue("[ERR] " + e.Data);
            };

            _sw.Start();
            if (!_process.Start())
                throw new InvalidOperationException("Failed to start process: " + fileName);

            ProcessId = _process.Id;
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
        }

        public bool HasExited
        {
            get
            {
                if (_disposed)
                    return true;
                if (!_process.HasExited)
                    return false;
                if (!_flushed)
                {
                    // WaitForExit() with no args flushes async stdout/stderr callbacks.
                    _process.WaitForExit();
                    _sw.Stop();
                    _flushed = true;
                }
                return true;
            }
        }

        public int ExitCode
        {
            get
            {
                if (!HasExited)
                    return -1;
                return _process.ExitCode;
            }
        }

        public long ElapsedMilliseconds
        {
            get { return _sw.ElapsedMilliseconds; }
        }

        public string[] DrainOutput()
        {
            var list = new List<string>();
            string line;
            while (_lines.TryDequeue(out line))
            {
                list.Add(line);
            }
            return list.ToArray();
        }

        public void KillTree()
        {
            if (_disposed)
                return;
            WasKilled = true;
            try
            {
                if (!_process.HasExited)
                {
                    _process.Kill(true);
                    _process.WaitForExit(3000);
                }
            }
            catch
            {
                // Best effort process tree termination.
            }
            finally
            {
                _sw.Stop();
            }
        }

        public void Dispose()
        {
            if (_disposed)
                return;
            _disposed = true;
            try
            {
                if (!_process.HasExited)
                {
                    _process.Kill(true);
                    _process.WaitForExit(2000);
                }
            }
            catch
            {
            }
            _process.Dispose();
        }
    }
}
