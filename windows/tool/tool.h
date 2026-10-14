// PitchShiftTool.exe: setup, repair and test commands that run without the window.
#pragma once
#include <string>
#include <vector>

namespace ps::tool {

struct Args {
    std::vector<std::wstring> items;
    bool has(const wchar_t* flag) const;
    std::wstring get(const wchar_t* flag, const std::wstring& fallback = L"") const;
    double number(const wchar_t* flag, double fallback) const;
    std::wstring positional(size_t index, const std::wstring& fallback = L"") const;  // after the command
};

int tonegen(const Args& args);
int diag(const Args& args);
int probe(const Args& args);
int restore(const Args& args);
int set_default(const Args& args);
int selftest(const Args& args);

// Prints a line to the console (UTF-8) and flushes it, so logs on GitHub show it right away.
void say(const std::string& line);

}  // namespace ps::tool
