// 文言 (tools/gen_i18n.py が生成した Resources/Strings*.resx)。既定 = ja。
using System.Globalization;
using System.Resources;
using System.Threading;

namespace DoorbellApp.Util
{
    public static class L10n
    {
        private static readonly ResourceManager Rm =
            new ResourceManager("DoorbellApp.Resources.Strings", typeof(L10n).Assembly);

        public static void SetLanguage(string lang)
        {
            var culture = lang == "en" ? new CultureInfo("en") :
                          lang == "zh" ? new CultureInfo("zh") : new CultureInfo("ja");
            Thread.CurrentThread.CurrentUICulture = culture;
            CultureInfo.DefaultThreadCurrentUICulture = culture;
        }

        /// <summary>key はドット区切り (resx 内ではアンダースコア化されている)。</summary>
        public static string T(string key, params object[] args)
        {
            string s = null;
            try { s = Rm.GetString(key.Replace('.', '_')); } catch { }
            if (string.IsNullOrEmpty(s)) s = key;
            if (args != null && args.Length > 0)
                try { s = string.Format(s, args); } catch { }
            return s;
        }
    }
}
