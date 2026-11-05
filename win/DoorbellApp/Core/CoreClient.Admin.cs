using System;
using System.Collections.Generic;

namespace DoorbellApp.Core
{
    // Native administration entry points that let the settings screen do everything the web
    // admin does: the asset ledger, device removal, the version 2 configuration snapshot and
    // commit, and the session-bound import and panel-identity services. Every export is optional;
    // a Core that predates one answers null and the row explains it instead of crashing.
    public sealed partial class CoreClient
    {
        private bool _adminProbed;
        private CoreInterop.AssetAddJsonFn _assetAdd;
        private CoreInterop.AssetRemoveJsonFn _assetRemove;
        private CoreInterop.ConfigSnapshotJsonV2Fn _configSnapshotV2;
        private CoreInterop.ConfigCommitJsonV2Fn _configCommitV2;
        private CoreInterop.SessionActionJsonV2Fn _configImportV2;
        private CoreInterop.SessionActionJsonV2Fn _panelIdentityV2;
        private CoreInterop.RemoveDeviceV2Fn _removeDeviceV2;

        /// <summary>The largest asset Core accepts (3 MiB).</summary>
        public const int MaxAssetBytes = 3 * 1024 * 1024;

        private void ProbeAdminExports()
        {
            lock (_nativeLock)
            {
                if (_adminProbed) return;
                _adminProbed = true;
                _assetAdd = CoreInterop.OptionalExport<CoreInterop.AssetAddJsonFn>(
                    "db_core_asset_add_json");
                _assetRemove = CoreInterop.OptionalExport<CoreInterop.AssetRemoveJsonFn>(
                    "db_core_asset_remove_json");
                _configSnapshotV2 = CoreInterop.OptionalExport<CoreInterop.ConfigSnapshotJsonV2Fn>(
                    "db_core_config_snapshot_json_v2");
                _configCommitV2 = CoreInterop.OptionalExport<CoreInterop.ConfigCommitJsonV2Fn>(
                    "db_core_config_commit_json_v2");
                _configImportV2 = CoreInterop.OptionalExport<CoreInterop.SessionActionJsonV2Fn>(
                    "db_core_config_import_json_v2");
                _panelIdentityV2 = CoreInterop.OptionalExport<CoreInterop.SessionActionJsonV2Fn>(
                    "db_core_panel_identity_json_v2");
                _removeDeviceV2 = CoreInterop.OptionalExport<CoreInterop.RemoveDeviceV2Fn>(
                    "db_core_remove_device_v2");
            }
        }

        public bool AssetsAvailable
        {
            get { ProbeAdminExports(); return _assetAdd != null && _assetRemove != null; }
        }

        /// <summary>
        /// Uploads one image or sound into the asset ledger. Returns Core's document
        /// ({ok,hash} or {ok:false,err}); an admin_required answer prompts once and retries.
        /// </summary>
        public Dictionary<string, object> AssetAdd(byte[] data, string type, string label)
        {
            ProbeAdminExports();
            if (_assetAdd == null) return Failure("unsupported");
            if (data == null || data.Length == 0) return Failure("empty");
            if (data.Length > MaxAssetBytes) return Failure("too_large");
            return AdminJson(() =>
            {
                lock (_nativeLock)
                    return _core == IntPtr.Zero ? null : CoreInterop.TakeUtf8(
                        _assetAdd(_core, data, new UIntPtr((uint)data.Length), type, label ?? ""));
            });
        }

        public Dictionary<string, object> AssetRemove(string sha256)
        {
            ProbeAdminExports();
            if (_assetRemove == null) return Failure("unsupported");
            if (string.IsNullOrEmpty(sha256)) return Failure("bad_hash");
            return AdminJson(() =>
            {
                lock (_nativeLock)
                    return _core == IntPtr.Zero ? null :
                        CoreInterop.TakeUtf8(_assetRemove(_core, sha256));
            });
        }

        /// <summary>
        /// Removes another device: 0 removed, -1 invalid (including this device), -2 this role
        /// cannot remove devices, -3 not persisted, -4 no export, -20 admin refused.
        /// </summary>
        public int RemoveDevice(string nodeId)
        {
            ProbeAdminExports();
            if (_removeDeviceV2 == null) return -4;
            if (string.IsNullOrEmpty(nodeId)) return -1;
            return AdminWrite(() =>
            {
                lock (_nativeLock)
                    return _core == IntPtr.Zero ? -1 : _removeDeviceV2(_core, nodeId);
            });
        }

        /// <summary>{schema_version:2, revision, config} without password digests.</summary>
        public string ConfigSnapshotJson()
        {
            ProbeAdminExports();
            if (_configSnapshotV2 == null) return null;
            lock (_nativeLock)
                return _core == IntPtr.Zero ? null : CoreInterop.TakeUtf8(_configSnapshotV2(_core));
        }

        public bool ConfigCommitAvailable
        {
            get { ProbeAdminExports(); return _configCommitV2 != null && _configSnapshotV2 != null; }
        }

        /// <summary>Conditional commit {schema_version:2, expected_revision, ops}.</summary>
        public Dictionary<string, object> ConfigCommit(string requestJson)
        {
            ProbeAdminExports();
            if (_configCommitV2 == null) return Failure("unsupported");
            return AdminJson(() =>
            {
                lock (_nativeLock)
                    return _core == IntPtr.Zero ? null :
                        CoreInterop.TakeUtf8(_configCommitV2(_core, requestJson));
            });
        }

        public bool PanelIdentityAvailable
        {
            get { ProbeAdminExports(); return _panelIdentityV2 != null; }
        }

        /// <summary>
        /// list / create / update / revoke / rotate. Requires the loopback administrator session
        /// (AdminHttpSession); a permission_denied answer drops it so the next call logs in.
        /// </summary>
        public Dictionary<string, object> PanelIdentity(string action, string requestJson)
        {
            ProbeAdminExports();
            if (_panelIdentityV2 == null) return Failure("unsupported");
            return SessionJson(_panelIdentityV2, action, requestJson);
        }

        public Dictionary<string, object> ConfigImport(string action, string requestJson)
        {
            ProbeAdminExports();
            if (_configImportV2 == null) return Failure("unsupported");
            return SessionJson(_configImportV2, action, requestJson);
        }

        /// <summary>Stores one secret in this device's DPAPI store under its bare name.</summary>
        public bool PutSecret(string name, string value)
        {
            if (_secretStore == null || string.IsNullOrEmpty(name) || string.IsNullOrEmpty(value))
                return false;
            try { return _secretStore.Put(name, value); }
            catch { return false; }
        }

        /// <summary>True when this device's secure store holds a value for the bare name.</summary>
        public bool HasSecret(string name)
        {
            if (_secretStore == null || string.IsNullOrEmpty(name)) return false;
            try { return !string.IsNullOrEmpty(_secretStore.Get(name)); }
            catch { return false; }
        }

        private Dictionary<string, object> SessionJson(CoreInterop.SessionActionJsonV2Fn fn,
                                                       string action, string requestJson)
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                AdminHttpSession.Tokens tokens = AdminHttpSession.Ensure();
                if (tokens == null) return Failure("admin_required");
                string text;
                lock (_nativeLock)
                    text = _core == IntPtr.Zero ? null : CoreInterop.TakeUtf8(
                        fn(_core, action, requestJson ?? "{}", tokens.Session, tokens.Csrf));
                var doc = Parse(text);
                if (Convert.ToString(Dig(doc, "error_code")) != "permission_denied") return doc;
                AdminHttpSession.Clear();
            }
            return Failure("permission_denied");
        }

        private Dictionary<string, object> AdminJson(Func<string> write)
        {
            string text = write();
            if (IsAdminRequired(text))
            {
                Func<bool> prompt = AdminPrompt;
                if (prompt != null && prompt()) text = write();
            }
            return Parse(text);
        }

        private Dictionary<string, object> Parse(string text)
        {
            if (string.IsNullOrEmpty(text)) return Failure("core_unavailable");
            try
            {
                return _json.Deserialize<Dictionary<string, object>>(text) ?? Failure("bad_result");
            }
            catch { return Failure("bad_result"); }
        }

        private static Dictionary<string, object> Failure(string err)
        {
            return new Dictionary<string, object> { { "ok", false }, { "err", err } };
        }
    }
}
