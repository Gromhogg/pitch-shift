using Xunit;

namespace PitchShift.Tests;

public class AmountTests
{
    [Theory]
    [InlineData(2, "+2")]
    [InlineData(-1.5, "−1.5")]
    [InlineData(0, "0")]
    [InlineData(-0.001, "0")]
    [InlineData(2.37, "+2.37")]
    [InlineData(12.5, "+12.5")]
    [InlineData(-24, "−24")]
    [InlineData(30, "+24")]
    [InlineData(1.006, "+1.01")]
    public void Display(double value, string shown) => Assert.Equal(shown, Amount.Display(value));

    [Theory]
    [InlineData(2.5, "2.5")]
    [InlineData(3, "3")]
    [InlineData(-1.25, "-1.25")]
    [InlineData(0, "0")]
    public void PlainWhileTyping(double value, string shown) => Assert.Equal(shown, Amount.Plain(value));

    [Theory]
    [InlineData("2", 2)]
    [InlineData("2,5", 2.5)]
    [InlineData("2.5", 2.5)]
    [InlineData("+3", 3)]
    [InlineData("−1.25", -1.25)]
    [InlineData("-1.25", -1.25)]
    [InlineData(" 4 ", 4)]
    [InlineData("1.234", 1.23)]
    [InlineData("1.235", 1.24)]
    [InlineData("99", 24)]
    [InlineData("-99", -24)]
    [InlineData(".5", 0.5)]
    [InlineData("-0", 0)]
    public void ParseAccepts(string typed, double expected) => Assert.Equal(expected, Amount.Parse(typed));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("abc")]
    [InlineData("2..5")]
    [InlineData("+")]
    [InlineData("-")]
    [InlineData("1e3")]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("2,5,1")]
    [InlineData(null)]
    public void ParseRejects(string? typed) => Assert.Null(Amount.Parse(typed));

    [Theory]
    [InlineData(2, 1, 3)]
    [InlineData(2.5, -1, 1.5)]
    [InlineData(23.5, 1, 24)]
    [InlineData(-24, -1, -24)]
    [InlineData(0.1, -1, -0.9)]
    public void Step(double value, int direction, double expected) => Assert.Equal(expected, Amount.Step(value, direction));

    [Fact]
    public void CleanRoundsAndClamps()
    {
        Assert.Equal(1.23, Amount.Clean(1.2345));
        Assert.Equal(24, Amount.Clean(1000));
        Assert.Equal(-24, Amount.Clean(double.NegativeInfinity));
        Assert.Equal(0, Amount.Clean(double.NaN));
    }
}
