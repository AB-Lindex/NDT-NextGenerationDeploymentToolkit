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
    //   POST /progress        Body = JSON progress object from a deploying machine.
    //                         Writes <MAC>.json (latest state) + appends audit.jsonl.
    //   GET  /progress        Returns a JSON array of every machine's latest state.
    //   GET  /progress?mac=X  Returns a single machine's latest state (dashes or colons).
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

            string mac = data.ContainsKey("MAC") && data["MAC"] != null
                ? data["MAC"].ToString() : "UNKNOWN";

            // Stamp the server-side receive time so stale machines are detectable.
            data["Received"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            string normalized = ser.Serialize(data);

            string stateFile = Path.Combine(LogRoot, SafeMac(mac) + ".json");
            File.WriteAllText(stateFile, normalized, Encoding.UTF8);
            File.AppendAllText(Path.Combine(LogRoot, "audit.jsonl"),
                normalized + Environment.NewLine, Encoding.UTF8);

            ctx.Response.Write("{\"ok\":true}");
        }

        private static void HandleGet(HttpContext ctx)
        {
            string macQuery = ctx.Request.QueryString["mac"];
            if (!string.IsNullOrEmpty(macQuery))
            {
                string file = Path.Combine(LogRoot, SafeMac(macQuery) + ".json");
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

        // Normalise a MAC to an uppercase, filesystem-safe filename stem.
        private static string SafeMac(string mac)
        {
            string s = mac.Replace(":", "-").ToUpperInvariant();
            foreach (char c in Path.GetInvalidFileNameChars())
                s = s.Replace(c.ToString(), "");
            return s;
        }
    }
}
