cmd /c "wasm-pack build --target web --dev --weak-refs"
$folderPath = '..\webpack\pkg'
if (Test-Path $folderPath) {
    Remove-Item -Path $folderPath -Recurse -Force
    Write-Host "pkg Folder deleted successfully."

} else {
    Write-Host "Folder does not exist."
}
Move-Item -Path '.\pkg' -Destination '..\webpack'
cd '..\webpack'
Start-Process -FilePath 'run.bat'
Write-Host "Done."