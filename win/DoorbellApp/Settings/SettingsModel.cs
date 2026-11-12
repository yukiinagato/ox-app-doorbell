using System;
using System.Collections.Generic;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// Declarative description of the native settings screen. Every editable row names the Core
    /// configuration key it writes; "{self}" stands for this device's node id. Labels and
    /// descriptions are i18n keys (settings.*). The window renders this model; nothing here
    /// touches WPF, so the contract tests can read it as plain data.
    /// </summary>
    internal enum SettingKind
    {
        Toggle, Slider, Stepper, Choice, Text, Time, MultiChoice,
        ListEditor, Action, Info,
        /// <summary>A full-width native editor (records, assets, panels, rules) named by Handler.</summary>
        Editor,
    }

    /// <summary>Where a value applies, shown under the label so the operator knows the reach.</summary>
    internal enum SettingScope { ThisDevice, AllDevices, Local }

    internal sealed class SettingOption
    {
        public readonly object Value;
        public readonly string LabelKey;
        /// <summary>Literal label for options built from configuration (asset names, doors).</summary>
        public readonly string Text;
        public SettingOption(object value, string labelKey)
        {
            Value = value;
            LabelKey = labelKey;
        }

        public SettingOption(object value, string labelKey, string text)
        {
            Value = value;
            LabelKey = labelKey;
            Text = text;
        }
    }

    internal sealed class SettingItem
    {
        public string Id;
        public SettingKind Kind;
        public string Key;
        public SettingScope Scope = SettingScope.AllDevices;
        public string LabelKey;
        public string DescriptionKey;
        public object Default;
        public double Min, Max, Step = 1;
        public string UnitKey;
        public List<SettingOption> Options;
        /// <summary>For ListEditor/Editor: which editor; for Action/Info: what to do or show.</summary>
        public string Handler;
        /// <summary>Writes that cannot take effect live: boot.json fields, role changes.</summary>
        public bool RequiresRestart;
        /// <summary>
        /// Destructive or security action (ui-guidelines 4, Settings): rendered last in its
        /// section, in the negative role, behind a confirmation that names the consequence.
        /// </summary>
        public bool Destructive;
        /// <summary>Shown only when this returns true for the current device.</summary>
        public Func<SettingsContext, bool> Visible;
        /// <summary>Further keys written to the same value, in the same batch.</summary>
        public string[] AlsoWrites;
        /// <summary>Further configuration keys this row's editor or form covers.</summary>
        public string[] AlsoCovers;
        /// <summary>
        /// For a secret row: the secure-store name ("{self}" allowed). The value goes to this
        /// device's DPAPI store and Key receives the reference "secret:&lt;name&gt;".
        /// </summary>
        public string Secret;

        public SettingItem Clone()
        {
            var copy = (SettingItem)MemberwiseClone();
            if (Options != null) copy.Options = new List<SettingOption>(Options);
            return copy;
        }

        public static SettingItem Make(string id, SettingKind kind, string key)
        {
            return new SettingItem
            {
                Id = id,
                Kind = kind,
                Key = key,
                LabelKey = "settings." + id,
            };
        }
    }

    internal sealed class SettingGroup
    {
        public string TitleKey;
        public readonly List<SettingItem> Items = new List<SettingItem>();
    }

    internal sealed class SettingCategory
    {
        public string Id;
        public string TitleKey;
        public string IconKey;
        public readonly List<SettingGroup> Groups = new List<SettingGroup>();
    }

    /// <summary>What the catalog needs to know about the device it is shown on.</summary>
    internal sealed class SettingsContext
    {
        public string NodeId = "";
        public string Role = "";
        public bool IsDoorStation { get { return Role == "door_station"; } }
    }
}
