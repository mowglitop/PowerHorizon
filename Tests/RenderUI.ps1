#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
$reader = [Xml.XmlReader]::Create((Join-Path $root 'UI/MainWindow.xaml'))
try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$tabs = $window.FindName('Workspace')
$surface = $window.Content
$window.Content = $null
$surface.Resources = $window.Resources
$surface.Background = $window.Background
$surface.SetValue([Windows.Documents.TextElement]::FontSizeProperty, 14.0)
$surface.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, [Windows.Media.FontFamily]::new('Segoe UI'))
$surface.SetValue([Windows.Documents.TextElement]::ForegroundProperty, $window.Foreground)
$out = Join-Path $root 'Exports/UI'
$null = New-Item -ItemType Directory -Path $out -Force
foreach ($index in 0..($tabs.Items.Count - 1)) {
    $tabs.SelectedIndex = $index
    $surface.Measure([Windows.Size]::new(1240,820))
    $surface.Arrange([Windows.Rect]::new(0,0,1240,820))
    $surface.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(1240,820,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($surface)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $out ("tab-$index.png")))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
$window.Close()
Write-Output 'Rendus WPF enregistrés dans Exports/UI.'




