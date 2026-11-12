using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ControlHelper = ModernWpf.Controls.Primitives.ControlHelper;
using IconElement = ModernWpf.Controls.IconElement;
using PathIcon = ModernWpf.Controls.PathIcon;
using ToggleSwitch = ModernWpf.Controls.ToggleSwitch;
using WindowHelper = ModernWpf.Controls.Primitives.WindowHelper;

namespace DoorbellApp.Ui
{
    /// <summary>
    /// The few ModernWpf entry points the code-built screens share, so each call site names the
    /// Fluent pattern it wants instead of repeating attached-property plumbing.
    /// </summary>
    internal static class Fluent
    {
        /// <summary>Touch minimum for every interactive control (ui-guidelines section 3).</summary>
        public const double TouchMin = 44;

        /// <summary>
        /// Gives a dialog or tool window the Fluent title bar, page background and text ink.
        /// Kiosk windows stay borderless and never call this.
        /// </summary>
        public static void StyleWindow(Window window)
        {
            WindowHelper.SetUseModernWindowStyle(window, true);
        }

        /// <summary>The label a Fluent text box, password box or combo box shows above itself.</summary>
        public static T WithHeader<T>(T control, string header) where T : Control
        {
            ControlHelper.SetHeader(control, header);
            return control;
        }

        public static void Placeholder(Control control, string text)
        {
            ControlHelper.SetPlaceholderText(control, text ?? "");
        }

        /// <summary>Turns a button into the screen's primary (accent) action.</summary>
        public static void MakeAccent(Button button)
        {
            var style = button.TryFindResource("AccentButtonStyle") as Style;
            if (style != null) button.Style = style;
        }

        /// <summary>
        /// A destructive command: outlined, in the negative text colour, with no fill, so its
        /// label is read against the card behind it and reaches 4.5:1 in both appearances.
        /// </summary>
        public static void MakeDestructive(Button button)
        {
            button.Background = Brushes.Transparent;
            button.SetResourceReference(Control.ForegroundProperty, "NegativeText");
            button.SetResourceReference(Control.BorderBrushProperty, "NegativeText");
            KeepOutlineStates(button, "NegativeText");
        }

        /// <summary>
        /// Keeps an outlined button readable while hovered or pressed. The Fluent template
        /// swaps in its own grey fill and ink for those states; these per-button resources
        /// replace them with a faint tint of the text ink and the button's own role colour, so
        /// the label stays at 4.5:1. Call it again after the appearance changes: the brushes
        /// are taken from the current theme.
        /// </summary>
        public static void KeepOutlineStates(Button button, string inkKey)
        {
            var ink = button.TryFindResource(inkKey) as Brush;
            var text = button.TryFindResource("Fg") as SolidColorBrush;
            if (ink == null || text == null) return;
            var tint = new SolidColorBrush(Color.FromArgb(
                (byte)System.Math.Round(255 * DoorbellApp.Util.RoleContrast.OutlineStateTint),
                text.Color.R, text.Color.G, text.Color.B));
            tint.Freeze();
            foreach (string state in new[] { "PointerOver", "Pressed" })
            {
                button.Resources["ButtonBackground" + state] = tint;
                button.Resources["ButtonForeground" + state] = ink;
                button.Resources["ButtonBorderBrush" + state] = ink;
            }
        }

        /// <summary>A switch without the library's own On/Off caption; the row label says it.</summary>
        public static ToggleSwitch Switch(bool on)
        {
            return new ToggleSwitch
            {
                IsOn = on,
                OnContent = "",
                OffContent = "",
                MinWidth = 0,
                MinHeight = TouchMin,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        /// <summary>
        /// A Tabler outline as a Fluent icon element. PathIcon fills its geometry, and Tabler
        /// icons are strokes, so the stroke is widened into the outline it would draw.
        /// </summary>
        public static IconElement Icon(string key)
        {
            var geometry = Application.Current == null
                ? null : Application.Current.TryFindResource(key) as Geometry;
            if (geometry == null) return null;
            var pen = new Pen(Brushes.Black, 2)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round,
                LineJoin = PenLineJoin.Round,
            };
            PathGeometry outline = geometry.GetWidenedPathGeometry(pen);
            // Round caps and joins overlap the segments they close; nonzero fills them solid.
            outline.FillRule = FillRule.Nonzero;
            outline.Freeze();
            return new PathIcon { Data = outline };
        }
    }
}
