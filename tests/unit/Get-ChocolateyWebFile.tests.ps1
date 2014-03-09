$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$common = Join-Path (Split-Path -Parent $here)  '_Common.ps1'
$base = Split-Path -parent (Split-Path -Parent $here)

. $common
. "$base\src\helpers\functions\Get-ChocolateyWebFile.ps1"
. "$base\src\helpers\functions\Get-WebFile.ps1"

$myPackageName = "mypackage"
$myUrl = "http://www.coolco.com/download/stuff-1.2.exe"
$cacheDir = 'TestDrive:\cacheDir'
$downloadDir = 'TestDrive:\downloadDir'
$myLocalPath = Join-Path $env:windir 'system32/cmd.exe'
$myFileUrl = "file:///$myLocalPath"

Describe "When calling Get-CachedInstallerFileNames" {

  Context "if no cache setting is set" {
    $env:ChocolateyInstallCachePath = $null

    $returnValue = Get-CachedInstallerFileNames -packageName $myPackageName -url $myUrl
  
    It "should return null" {
      $returnValue | should Be $null
    }
  }

  Context "if caching a sensible url" {
    $env:ChocolateyInstallCachePath = $cacheDir

    $returnValue = Get-CachedInstallerFileNames -packageName $myPackageName -url $myUrl
  
    It "should return a sensible entry object" {
      $returnValue.nameFile | should Be 'TestDrive:\cacheDir\mypackage_http_www.coolco.com_download_stuff-1.2.exe_CBC96497922AECCD8CE22963874FC643.txt'
      $returnValue.binFile | should Be 'TestDrive:\cacheDir\mypackage_http_www.coolco.com_download_stuff-1.2.exe_CBC96497922AECCD8CE22963874FC643.bin'
    }
  }

  Context "if caching a silly url" {
    $env:ChocolateyInstallCachePath = $cacheDir

    $returnValue = Get-CachedInstallerFileNames -packageName $myPackageName -url "http://www.coolco.com/download/stuff-1.2.exe&*()E$234233asdf?890890890`4534££$%^@'"
  
    It "should return safe filenames" {
      $nameFileFilename = [io.path]::GetFileName($returnValue.nameFile)
      $nameFileFilename | Should Match '^[A-Za-z0-9_.-]*$'
    }
  }

  Context "if caching a very long url" {
    $env:ChocolateyInstallCachePath = $cacheDir

    $urlLong = $myUrl * 16
    $returnValue = Get-CachedInstallerFileNames -packageName $myPackageName -url $urlLong
  
    It "should truncate safely" {
      # 128 = truncation of url, 32 for md5 in hex, 2 joining underscores, 4 for ".txt" extension
      # -> 166 plus myPackageName.Length
      $maxFilenameLength = $myPackageName.Length + 128 + 32 + 2 + 4

      $nameFileFilename = [io.path]::GetFileName($returnValue.nameFile)

      $urlLong.Length -le $maxFilenameLength | should Be $false
      $nameFileFilename.Length | should Be $maxFilenameLength
    }
  }
}

Describe "When calling Handle-CachedPackageInstaller" {

  Context "if not caching" {
    Mock Get-CachedInstallerFileNames {$null} -Verifiable -ParameterFilter {$packageName -eq $myPackageName -and $url -eq $myUrl}
    $env:ChocolateyInstallCachePath = ""

    $fullInstallerPath = ""
    $returnValue = Handle-CachedPackageInstaller -packageName $myPackageName -url $myUrl -fileFullPath $downloadDir -actualOutputPath ([ref]$fullInstallerPath)

    It "should not make the cache dir at all" {
      Assert-VerifiableMocks
      $returnValue | Should Be $false
      Test-Path -Path $cacheDir -PathType Container | Should Be $false
    }
  }

  Context "if caching with empty cache" {
    Setup -Dir 'cacheDir'
    Mock Get-CachedInstallerFileNames {return @{nameFile='TestDrive:\cacheDir\N.txt'; binFile='TestDrive:\cacheDir\N.bin'}} -Verifiable -ParameterFilter {$packageName -eq $myPackageName -and $url -eq $myUrl}
    $env:ChocolateyInstallCachePath = $cacheDir

    $fullInstallerPath = ""
    $returnValue = Handle-CachedPackageInstaller -packageName $myPackageName -url $myUrl -fileFullPath $downloadDir -actualOutputPath ([ref]$fullInstallerPath)

    It "should not fail/return false" {
      Assert-VerifiableMocks
      $returnValue | Should Be $false
    }
  }

  Context "if caching with full cache" {
    Setup -Dir 'cacheDir'
    Setup -Dir 'downloadDir'
    Setup -File 'cacheDir\N.txt' 'x.dat'
    Setup -File 'cacheDir\N.bin' '12345'
    Mock Get-CachedInstallerFileNames {return @{nameFile='TestDrive:\cacheDir\N.txt'; binFile='TestDrive:\cacheDir\N.bin'}} -Verifiable -ParameterFilter {$packageName -eq $myPackageName -and $url -eq $myUrl}
    $env:ChocolateyInstallCachePath = $cacheDir

    $fullInstallerPath = ""
    $returnValue = Handle-CachedPackageInstaller -packageName $myPackageName -url $myUrl -fileFullPath $downloadDir -actualOutputPath ([ref]$fullInstallerPath)

    It "should reuse the prior file" {
      Assert-VerifiableMocks
      $returnValue | Should Be $true
      Test-Path -Path $fullInstallerPath -PathType Leaf | Should Be $true
      $fullInstallerPath | Should Be "TestDrive:\downloadDir\x.dat"
      Get-Content $fullInstallerPath | Should Be '12345'
    }
  }
}

Describe "When calling Copy-DownloadedFileToCachePath" {

  Context "if not caching" {
    Setup -File 'downloadDir\dummy.dat' 'X'
    $env:ChocolateyInstallCachePath = ""

    Copy-DownloadedFileToCachePath 'TestDrive:\downloadDir\dummy.dat' $myUrl $myPackageName

    It "should not make the cache dir at all" {
      Test-Path $cacheDir -PathType Container | Should Be $false
    }
  }

  Context "if caching" {
    $env:ChocolateyInstallCachePath = $cacheDir
    Setup -File 'downloadDir\dummy.dat' 'X'

    Copy-DownloadedFileToCachePath 'TestDrive:\downloadDir\dummy.dat' $myUrl $myPackageName

    It "should copy the file and filename to the cache dir" {
      $baseCacheName = "$cacheDir\mypackage_http_www.coolco.com_download_stuff-1.2.exe_CBC96497922AECCD8CE22963874FC643"
      Test-Path $cacheDir -PathType Container | Should Be $true
      Test-Path "$baseCacheName.bin" | Should Be $true
      Get-Content "$baseCacheName.bin" | Should Be 'X'
      Test-Path "$baseCacheName.txt" | Should Be $true
      Get-Content "$baseCacheName.txt" | Should Be 'dummy.dat'
    }
  }
}

Describe "When calling Get-ChocolateyWebFile" {
  Setup -Dir 'downloadDir'
  $expectedDownloadLocation = Join-Path $downloadDir 'cmd.exe'

  Context "if downloading with an empty cache" {
    Mock Handle-CachedPackageInstaller { $false } -Verifiable -ParameterFilter {$packageName -eq $myPackageName -and $url -eq $myFileUrl}
    Mock Copy-DownloadedFileToCachePath -Verifiable -ParameterFilter {$url -eq $myLocalPath -and $downloadLocation -eq $expectedDownloadLocation -and $packageName -eq $myPackageName}
    $env:ChocolateyInstallCachePath = $cacheDir

    $actualOutputPath = ''
    Get-ChocolateyWebFile $myPackageName $downloadDir $myFileUrl $myFileUrl ([ref]$actualOutputPath)

    It "should download and fill the cache with the new file" {
      $actualOutputPath | Should Be $expectedDownloadLocation
      Assert-VerifiableMocks
    }
  }

  Context "if downloading with an full cache" {
    Mock Handle-CachedPackageInstaller { ([ref]$fullInstallerPath).Value = $expectedDownloadLocation; $true } -Verifiable -ParameterFilter {$packageName -eq $myPackageName -and $url -eq $myFileUrl}
    Mock Copy-DownloadedFileToCachePath
    $env:ChocolateyInstallCachePath = $cacheDir

    $actualOutputPath = ''
    Get-ChocolateyWebFile $myPackageName $downloadDir $myFileUrl $myFileUrl ([ref]$actualOutputPath)

    It "should not proceed to download or store for later" {
      $actualOutputPath | Should Be $expectedDownloadLocation
      Assert-VerifiableMocks
      Assert-MockCalled Copy-DownloadedFileToCachePath -Times 0
    }
  }
}