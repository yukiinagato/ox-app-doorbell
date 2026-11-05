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
        ListEditor, Action, Info, WebOnly,
    }

    /// <summary>Where a value applies, shown under the label so the operator knows the reach.</summary>
    internal enum SettingScope { ThisDevice, AllDevices, Local }

    internal sealed class SettingOption
    {
        public readonly object Value;
        public readonly string LabelKey;
        public SettingOption(object value, string labelKey)
        {
            Value = value;
            LabelKey = labelKey;
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
        /// <summary>For ListEditor: which editor; for Action/WebOnly/Info: what to do or show.</summary>
        public string Handler;
        /// <summary>Writes that cannot take effect live: boot.json fields, role changes.</summary>
        public bool RequiresRestart;
        /// <summary>Shown only when this returns true for the current device.</summary>
        public Func<SettingsContext, bool> Visible;
        /// <summary>Further keys written to the same value, in the same batch.</summary>
        public string[] AlsoWrites;

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
