# PowerShell script to update shader metadata structures

$shaderFiles = @(
    "Run\Data\Shaders\CombineSurfaceCache\SurfaceCacheCombine.hlsl",
    "Run\Data\Shaders\ScreenProbe\RadianceComposite.hlsl",
    "Run\Data\Shaders\ScreenProbe\MeshSDFTrace_Debug.hlsl",
    "Run\Data\Shaders\ScreenProbe\MeshSDFTrace.hlsl",
    "Run\Data\Shaders\InjectVoxelLighting.hlsl",
    "Run\Data\Shaders\SurfaceRadiosity\ConvertToSH.hlsl",
    "Run\Data\Shaders\SurfaceRadiosity\IntegrateSH.hlsl",
    "Run\Data\Shaders\SurfaceRadiosity\RadiosityTrace.hlsl",
    "Run\Data\Shaders\BuildGlobalSDF.hlsl",
    "Run\Data\Shaders\RadianceCacheUpdate.hlsl"
)

$basePath = "C:\Users\carlo\Perforce\ruotongg_IglooPersonal\C34\Students\ruotongg\SD\LuminaGI\"

foreach ($file in $shaderFiles) {
    $fullPath = Join-Path $basePath $file

    if (Test-Path $fullPath) {
        Write-Host "Processing: $file"

        $content = Get-Content $fullPath -Raw

        # Replace Padding0-3 with new names
        $content = $content -replace '(\s+)float\s+Padding0;', '$1float ObjectYaw;         // Object yaw (degrees)'
        $content = $content -replace '(\s+)float\s+Padding1;', '$1float ObjectPitch;       // Object pitch (degrees)'
        $content = $content -replace '(\s+)float\s+Padding2;', '$1float ObjectRoll;        // Object roll (degrees)'
        $content = $content -replace '(\s+)float\s+Padding3;', '$1float ObjectPosX;        // Object world position X'

        # Add new fields after WorldSizeY
        # Pattern 1: When WorldSizeX and WorldSizeY are on separate lines
        $content = $content -replace '(float\s+WorldSizeY;[^\n]*\n)(\s+)(uint\s+Direction)', '$1$2float ObjectPosY;        // Object world position Y' + "`n" + '$2float ObjectPosZ;        // Object world position Z' + "`n`n" + '$2$3'

        # Pattern 2: When WorldSizeY and Direction are on the same line comment block
        $content = $content -replace '(float\s+WorldSizeY;.*?)(uint\s+Direction)', '$1' + "`n    float ObjectPosY;`n    float ObjectPosZ;`n`n    " + '$2'

        # Add Padding4 and Padding5 after GlobalCardID
        $content = $content -replace '(uint\s+GlobalCardID;[^\n]*\n)(\s+)(uint4\s+LightMask)', '$1$2uint Padding4;' + "`n" + '$2uint Padding5;' + "`n`n" + '$2$3'

        # Update total size comment if present
        $content = $content -replace '//\s*Total:\s*112\s*bytes', '// Total: 128 bytes'

        Set-Content -Path $fullPath -Value $content -NoNewline
        Write-Host "  ✓ Updated successfully"
    }
    else {
        Write-Host "  ✗ File not found: $fullPath"
    }
}

Write-Host "`nAll files processed!"
