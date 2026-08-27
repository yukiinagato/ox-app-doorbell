// boot.json — 端末ローカルの起動設定 (provision 時に配置)。fleet 設定は core が CRDT で持つ。
// 例: { "name":"genkan-front", "role":"door_station", "door":"d_front",
//       "listen_port":47172, "http_port":47180, "psk_hex":"…64hex…",
//       "seed_peers":["10.0.1.10:47172"], "ui_lang":"ja", "kiosk":true }
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace DoorbellApp
{
    public sealed class BootConfig
    {
        public string RawJson = "{}";
        public string Name = "doorbell";
        public string Door = "";
        public string UiLang = "ja";
        public bool Kiosk = true;

        public static BootConfig Load(string path)
        {
            var c = new BootConfig();
            if (!File.Exists(path))
            {
                // 初回: 既定 boot.json を書き出しておく (管理者が編集できるように)
                c.RawJson = "{ \"name\": \"doorbell-win\", \"role\": \"door_station\", \"door\": \"\", " +
                            "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": false }";
                try { File.WriteAllText(path, c.RawJson); } catch { }
            }
            else
            {
                c.RawJson = File.ReadAllText(path);
            }
            try
            {
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(c.RawJson);
                if (d != null)
                {
                    if (d.TryGetValue("name", out var n) && n != null) c.Name = n.ToString();
                    if (d.TryGetValue("door", out var dr) && dr != null) c.Door = dr.ToString();
                    if (d.TryGetValue("ui_lang", out var l) && l != null) c.UiLang = l.ToString();
                    if (d.TryGetValue("kiosk", out var k) && k is bool kb) c.Kiosk = kb;
                }
            }
            catch { }
            return c;
        }
    }
}
