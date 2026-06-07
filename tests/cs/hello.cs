/*
 * tests/hello.cs
 * Minimal C# test — requires dotnet SDK installed.
 * Run with: crun tests/hello.cs
 * Note: crun will generate a temporary .csproj if none exists.
 */
using System;

class Hello {
    static void Main() {
        Console.WriteLine("crun: C# compilation OK");
    }
}