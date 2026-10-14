using System.Globalization;

namespace PitchShift;

// The big number: half-steps from −24 to 24, shown like "+2", "−1.5" or "0".
public static class Amount
{
    public const double Min = -24, Max = 24;

    // Keeps a value inside −24…24 and rounds it to 0.01.
    public static double Clean(double value)
    {
        if (double.IsNaN(value)) return 0;
        var rounded = Math.Round(Math.Clamp(value, Min, Max) * 100, MidpointRounding.AwayFromZero) / 100;
        return rounded == 0 ? 0 : rounded;  // no "−0"
    }

    // What the card shows: "+2", "−1.5" (with a real minus sign), "0".
    public static string Display(double value)
    {
        var v = Clean(value);
        if (v == 0) return "0";
        return (v > 0 ? "+" : "−") + Plain(Math.Abs(v));
    }

    // What the box shows while typing: "2.5", "-1.25", "3".
    public static string Plain(double value) =>
        Clean(value).ToString("0.##", CultureInfo.InvariantCulture);

    // Typed text to a number. Accepts "2,5", "−1.25", "+3". Gives null when it isn't a number.
    public static double? Parse(string? text)
    {
        if (text is null) return null;
        var cleaned = text.Trim()
            .Replace('−', '-').Replace('–', '-')
            .Replace(',', '.');
        if (cleaned.StartsWith('+')) cleaned = cleaned[1..];
        if (cleaned.Length == 0) return null;
        if (!double.TryParse(cleaned, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint,
                CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number))
            return null;
        return Clean(number);
    }

    // The − and + buttons: one half-step down or up.
    public static double Step(double value, int direction) => Clean(value + direction);
}
