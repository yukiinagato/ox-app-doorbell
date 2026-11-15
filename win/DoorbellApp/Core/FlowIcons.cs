using System.Collections.Generic;

namespace DoorbellApp.Core
{
    /// <summary>
    /// Which vendored Fluent icon stands for a purpose or an option. Configuration carries an
    /// emoji (or nothing) as the icon; the shell never draws it and maps it to the same small set
    /// of glyphs on every option: house, package, envelope, briefcase, wrench, ellipsis, and a
    /// person for anything it does not know.
    /// </summary>
    internal static class FlowIcons
    {
        public const string Home = "IconHome";
        public const string Package = "IconPackage";
        public const string Mail = "IconMail";
        public const string Briefcase = "IconBriefcase";
        public const string Wrench = "IconWrench";
        public const string Other = "IconDots";
        public const string Person = "IconUser";

        private static readonly Dictionary<string, string> ByPurpose = new Dictionary<string, string>
        {
            { "p_visit", Home }, { "p_delivery", Package }, { "p_mail", Mail },
            { "p_sales", Briefcase }, { "p_utility", Wrench }, { "p_other", Other },
        };

        // The first code point decides: a variation selector or a joiner behind it does not.
        private static readonly Dictionary<int, string> ByEmoji = new Dictionary<int, string>
        {
            { 0x1F3E0, Home }, { 0x1F3E1, Home }, { 0x1F3D8, Home },
            { 0x1F4E6, Package }, { 0x1F69A, Package }, { 0x1F6D2, Package },
            { 0x2709, Mail }, { 0x1F4EE, Mail }, { 0x1F4E7, Mail }, { 0x1F4E9, Mail }, { 0x1F4EC, Mail },
            { 0x1F4BC, Briefcase }, { 0x1F6CD, Briefcase }, { 0x1F454, Briefcase }, { 0x1F4B4, Briefcase },
            { 0x1F527, Wrench }, { 0x1F6E0, Wrench }, { 0x1F528, Wrench }, { 0x1F9F0, Wrench },
            { 0x2022, Other }, { 0x2026, Other }, { 0x22EF, Other }, { 0x2753, Other }, { 0x2754, Other },
            { 0x1F464, Person }, { 0x1F9D1, Person },
        };

        /// <summary>The picker's choices: the emoji written to configuration, in listing order.</summary>
        public static readonly string[] PickerEmoji =
        {
            "\U0001F3E0", "\U0001F4E6", "✉️", "\U0001F4BC", "\U0001F527", "⋯", "\U0001F464",
        };

        public static string KeyOfEmoji(string emoji)
        {
            if (string.IsNullOrEmpty(emoji)) return null;
            string key;
            return ByEmoji.TryGetValue(char.ConvertToUtf32(emoji, 0), out key) ? key : Person;
        }

        /// <summary>
        /// The glyph for an option or purpose. A seeded purpose id wins; otherwise the emoji is
        /// mapped; a purpose without a usable icon, or an unknown emoji, shows the person. Null
        /// only when there is neither a purpose nor an icon (a plain "ring" option).
        /// </summary>
        public static string KeyFor(string purposeId, string emoji)
        {
            string key;
            if (!string.IsNullOrEmpty(purposeId) && ByPurpose.TryGetValue(purposeId, out key)) return key;
            if (!string.IsNullOrEmpty(emoji))
            {
                try { return KeyOfEmoji(emoji); }
                catch (System.ArgumentException) { return Person; }
            }
            return string.IsNullOrEmpty(purposeId) ? null : Person;
        }
    }
}
