using System;
using System.Collections.Generic;
using System.Configuration;
using System.IO;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

namespace NDTMonitor
{
    // NDT deployment progress endpoint.
    //
    //   POST /progress         Body = JSON progress object from a deploying machine.
    //                          Writes <Computername>.json (latest state) + appends audit.jsonl.
    //   GET  /progress         Returns a JSON array of every machine's latest state.
    //   GET  /progress?name=X  Returns a single machine's latest state by computer name.
    //
    // Machines are keyed by Computername (not MAC): a VM's MAC can change in a
    // Hyper-V farm, but its name is stable for the life of the deployment.
    //
    // Storage folder is read from the "LogRoot" appSetting in web.config
    // (rewritten by Install-NDTMonitor to the real path).
    public class ProgressHandler : IHttpHandler
    {
        public bool IsReusable { get { return false; } }

        private static string LogRoot
        {
            get
            {
                string v = ConfigurationManager.AppSettings["LogRoot"];
                return string.IsNullOrEmpty(v) ? @"C:\Deploy2026\Logs\progress" : v;
            }
        }

        public void ProcessRequest(HttpContext ctx)
        {
            ctx.Response.ContentType = "application/json; charset=utf-8";
            Directory.CreateDirectory(LogRoot);

            try
            {
                switch (ctx.Request.HttpMethod)
                {
                    case "POST":
                        HandlePost(ctx);
                        break;
                    case "GET":
                        HandleGet(ctx);
                        break;
                    default:
                        ctx.Response.StatusCode = 405;
                        ctx.Response.Write("{\"error\":\"method not allowed\"}");
                        break;
                }
            }
            catch (Exception ex)
            {
                // Do not leak internal details (paths, stack) to the client.
                // Log server-side for diagnostics; return a generic error body.
                try { System.Diagnostics.Trace.TraceError("NDT Monitor error: " + ex); } catch { }
                ctx.Response.StatusCode = 500;
                ctx.Response.Write("{\"error\":\"internal error\"}");
            }
        }

        private static void HandlePost(HttpContext ctx)
        {
            string body;
            using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                body = reader.ReadToEnd();

            var ser = new JavaScriptSerializer();
            var data = ser.Deserialize<Dictionary<string, object>>(body);
            if (data == null) data = new Dictionary<string, object>();

            // Identify machines by name; fall back to MAC only if the name is absent.
            string name = data.ContainsKey("Computername") && data["Computername"] != null
                ? data["Computername"].ToString() : null;
            if (string.IsNullOrEmpty(name))
                name = data.ContainsKey("MAC") && data["MAC"] != null
                    ? data["MAC"].ToString() : "UNKNOWN";

            // Stamp the server-side receive time so stale machines are detectable.
            data["Received"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            string normalized = ser.Serialize(data);

            string stateFile = Path.Combine(LogRoot, SafeName(name) + ".json");
            File.WriteAllText(stateFile, normalized, Encoding.UTF8);

            // Append to a per-day audit log (audit-yyyy-MM-dd.jsonl) so the trail
            // rolls over automatically each day. Files are retained indefinitely;
            // housekeeping/retention is handled separately.
            string auditFile = Path.Combine(LogRoot,
                "audit-" + DateTime.Now.ToString("yyyy-MM-dd") + ".jsonl");
            AppendAudit(auditFile, normalized);

            ctx.Response.Write("{\"ok\":true}");
        }

        private static void HandleGet(HttpContext ctx)
        {
            string nameQuery = ctx.Request.QueryString["name"];
            if (!string.IsNullOrEmpty(nameQuery))
            {
                string file = Path.Combine(LogRoot, SafeName(nameQuery) + ".json");
                if (File.Exists(file))
                {
                    ctx.Response.Write(File.ReadAllText(file, Encoding.UTF8));
                }
                else
                {
                    ctx.Response.StatusCode = 404;
                    ctx.Response.Write("{\"error\":\"not found\"}");
                }
                return;
            }

            var sb = new StringBuilder();
            sb.Append("[");
            bool first = true;
            foreach (string f in Directory.GetFiles(LogRoot, "*.json"))
            {
                string content = File.ReadAllText(f, Encoding.UTF8).Trim();
                if (content.Length == 0) continue;
                if (!first) sb.Append(",");
                sb.Append(content);
                first = false;
            }
            sb.Append("]");
            ctx.Response.Write(sb.ToString());
        }

        // Normalise a computer name to an uppercase, filesystem-safe filename stem.
        private static string SafeName(string name)
        {
            string s = name.Replace(":", "-").ToUpperInvariant();
            foreach (char c in Path.GetInvalidFileNameChars())
                s = s.Replace(c.ToString(), "");
            return s;
        }

        // Append one line to the audit log, retrying briefly if another concurrent
        // request holds the file. Prevents lost audit records when many machines
        // report at the same instant (the append is not otherwise serialized).
        private static void AppendAudit(string path, string line)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(line + Environment.NewLine);
            const int maxAttempts = 10;
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    // FileShare.Read lets readers tail the file while we hold the write lock.
                    using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read))
                    {
                        fs.Write(bytes, 0, bytes.Length);
                    }
                    return;
                }
                catch (IOException)
                {
                    if (attempt >= maxAttempts) throw;
                    System.Threading.Thread.Sleep(20);
                }
            }
        }
    }
}
