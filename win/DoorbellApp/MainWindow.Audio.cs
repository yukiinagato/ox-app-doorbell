using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Media;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DoorbellApp.Core;
using DoorbellApp.Kiosk;
using DoorbellApp.Pairing;
using DoorbellApp.Util;


namespace DoorbellApp
{
    // Chime, launch sound and volume handling.
    public partial class MainWindow
    {
        private void PlayAudio(string path, Action fallback)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                _audioFallback = null;
                if (fallback != null) fallback();
                return;
            }
            _audioFallback = fallback;
            try
            {
                if (_audio == null)
                {
                    _audio = new MediaPlayer();
                    _audio.Volume = _volumeCall / 100.0;
                    _audio.MediaFailed += (s, e) =>
                    {
                        Debug.WriteLine("Custom audio playback failed; using fallback: " + e.ErrorException);
                        var fb = _audioFallback;
                        _audioFallback = null;
                        if (fb != null) fb();
                    };
                }
                _audio.Volume = _volumeCall / 100.0;
                _audio.Open(new Uri(path));
                _audio.Play();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Custom audio could not be opened; using fallback: " + ex.Message);
                _audioFallback = null;
                if (fallback != null) fallback();
            }
        }

        private string SoundValue(string key, string fallback)
        {
            var value = CoreClient.Dig(_cfg, "ui." + key);
            return value is string ? (string)value : fallback;
        }

        private bool ConfigBool(string path, bool fallback)
        {
            var value = CoreClient.Dig(_cfg, path);
            return value is bool ? (bool)value : fallback;
        }

        private static string BundledSoundFile(string value)
        {
            switch (value)
            {
                case "outdoor_call_alert": return "outdoor_call_alert.mp3";
                case "button_click": return "button_click.mp3";
                case "school_chime": return "学校のチャイム.mp3";
                case "indoor_update": return "indoor_update.mp3";
                case "title_display": return "title_display.mp3";
                default: return null;
            }
        }

        /// <summary>
        /// Effective 呼出 / SOS / 通常 volumes for this device, resolved by core from the device
        /// override and the cluster default (db_core_audio_json).
        /// </summary>
        private void ApplyAudioVolumes(Dictionary<string, object> levels)
        {
            if (levels == null) return;
            _volumeCall = Clamp(DictInt(levels, "call", _volumeCall));
            _volumeSos = Clamp(DictInt(levels, "sos", _volumeSos));
            _volumeIdle = Clamp(DictInt(levels, "idle", _volumeIdle));
        }

        private static int Clamp(int percent)
        {
            return percent < 0 ? 0 : (percent > 100 ? 100 : percent);
        }

        private MediaPlayer PlayConfigured(MediaPlayer current, string value, bool loop,
                                           Action fallback = null, int volumePercent = -1)
        {
            StopPlayer(ref current);
            if (string.IsNullOrEmpty(value)) return null;
            string path = null;
            if (value.StartsWith("asset:") && value.Length == 70)
                path = Path.Combine(App.DataDir, "assets", value.Substring(6));
            else
            {
                var filename = BundledSoundFile(value);
                if (filename != null)
                    path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Audio", filename);
            }
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                fallback?.Invoke();
                return null;
            }
            try
            {
                var player = new MediaPlayer
                { Volume = volumePercent < 0 ? 1.0 : Clamp(volumePercent) / 100.0 };
                player.MediaEnded += (s, e) =>
                {
                    if (loop) { player.Position = TimeSpan.Zero; player.Play(); }
                };
                player.MediaFailed += (s, e) => fallback?.Invoke();
                player.Open(new Uri(path));
                player.Play();
                return player;
            }
            catch
            {
                fallback?.Invoke();
                return null;
            }
        }

        private static void StopPlayer(ref MediaPlayer player)
        {
            if (player == null) return;
            try { player.Stop(); player.Close(); } catch { }
            player = null;
        }

        private static int DictInt(Dictionary<string, object> d, string key, int def)
        {
            object v;
            if (d != null && d.TryGetValue(key, out v) && v != null)
            {
                int i;
                if (int.TryParse(v.ToString(), out i)) return i;
            }
            return def;
        }

        private static long DictLong(Dictionary<string, object> d, string key, long def)
        {
            object value;
            long number;
            return d != null && d.TryGetValue(key, out value) && value != null &&
                   long.TryParse(value.ToString(), out number) ? number : def;
        }

        private static double DictDouble(Dictionary<string, object> d, string key, double def)
        {
            object value;
            double number;
            return d != null && d.TryGetValue(key, out value) && value != null &&
                   double.TryParse(value.ToString(), out number) &&
                   !double.IsNaN(number) && !double.IsInfinity(number) ? number : def;
        }

        private static bool DictBool(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v is bool && (bool)v;
        }
    }
}
