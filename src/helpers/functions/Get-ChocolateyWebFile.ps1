function Get-ChocolateyWebFile {
<#
.SYNOPSIS
Downloads a file from the internets.

.DESCRIPTION
This will download a file from a url, tracking with a progress bar.
It returns the filepath to the downloaded file when it is complete.

.PARAMETER PackageName
The name of the package we want to download - this is arbitrary, call it whatever you want.
It's recommended you call it the same as your nuget package id.

.PARAMETER FileFullPath
This is the full path of the resulting file name.

.PARAMETER Url
This is the url to download the file from.

.PARAMETER Url64bit
OPTIONAL - If there is an x64 installer to download, please include it here. If not, delete this parameter

.EXAMPLE
Get-ChocolateyWebFile '__NAME__' 'C:\somepath\somename.exe' 'URL' '64BIT_URL_DELETE_IF_NO_64BIT'

.NOTES
This helper reduces the number of lines one would have to write to download a file to 1 line.
There is no error handling built into this method.

.LINK
Install-ChocolateyPackage
#>
param(
  [string] $packageName,
  [string] $fileFullPath,
  [string] $url,
  [string] $url64bit = '',
  [ref]$actualOutputPath
)
  Write-Debug "Running 'Get-ChocolateyWebFile' for $packageName with url:`'$url`', fileFullPath:`'$fileFullPath`',and url64bit:`'$url64bit`'";

  #This URL is only for caching the downloaded file (If installing 32 bit package, the 64 bit package is cached)
  $cacheOnlyUrl = $url64bit
  $cacheOnlyBitwidth = 64

  $url32bit = $url;
  $bitWidth = 32
  
  
  if (Get-ProcessorBits 64) {
    $bitWidth = 64

  }
  Write-Debug "CPU is $bitWidth bit"

  $bitPackage = 32
  if ($bitWidth -eq 64 -and $url64bit -ne $null -and $url64bit -ne '') {
    Write-Debug "Setting url to '$url64bit' and bitPackage to $bitWidth"
    $bitPackage = $bitWidth
    $url = $url64bit;
    
    #When installing the 64 bit version, we also want to download and cache (not install) the 32 bit version
    $cacheOnlyUrl = $url32bit;
    $cacheOnlyBitwidth = 32

  }

  #Take care of checking for locally cached installers
  $fullInstallerPath = ""
  if(Handle-CachedPackageInstaller -packageName $packageName -url $url -fileFullPath $fileFullPath -actualOutputPath ([ref]$fullInstallerPath)) {
    Write-Debug "Using cached WebFile at $fullInstallerPath"
    if($actualOutputPath) { $actualOutputPath.Value = $fullInstallerPath}
    return;
  }

  #default the actual download location of the installer to the provided path (Get-WebFile will change this)
  $downloadLocation = $fileFullPath


  Write-Host "Downloading $packageName $bitWidth bit ($url) to $fileFullPath"
  #$downloader = new-object System.Net.WebClient
  #$downloader.DownloadFile($url, $fileFullPath)
  if ($url.StartsWith('http')) {
    $downloadLocation = ""
    Get-WebFile -url $url -filename $fileFullPath -actualOutputPath ([ref]$downloadLocation)

    #Also download and cache the other bitwidth URL
    if($url64Bit -and ($url32bit -notlike $url64bit)) {
        $cacheDownloadLocation = ""
        Get-WebFile -url $cacheOnlyUrl -filename $fileFullPath -actualOutputPath ([ref]$cacheDownloadLocation)
        Copy-DownloadedFileToCachePath -downloadLocation $cacheDownloadLocation -url $cacheOnlyUrl -packageName $packageName
    }

  } elseif ($url.StartsWith('ftp')) {
      $downloadLocation =  $fileFullPath
      
    #if the $fileFullPath is a directory, then pull the file name from the source URL
    if(Test-Path $fileFullPath -PathType Container) {
        $requestUri = new-object System.Uri ($url)
        $downloadLocation = Join-Path $fileFullPath ([io.path]::GetFileName($requestUri.LocalPath))
    }
    Get-FtpFile $url $fileFullPath
  } else {
    if ($url.StartsWith('file:')) { $url = ([uri] $url).LocalPath }
    Write-Debug "We are attempting to copy the local item `'$url`' to `'$fileFullPath`'"

    $downloadLocation =  $fileFullPath
    #if the $fileFullPath is a directory, then pull the file name from the source URL
    if(Test-Path $fileFullPath -PathType Container) {
        $downloadLocation = Join-Path $fileFullPath ([io.path]::GetFileName($url))
    }
    Copy-Item $url -Destination $fileFullPath -Force 
  }
  #If the caller has provided a [ref] variable, set it to the location where the file was downloaded
    if($actualOutputPath) {
      $actualOutputPath.Value = $downloadLocation
    }
  
    Copy-DownloadedFileToCachePath -downloadLocation $downloadLocation -url $url -packageName $packageName


  Start-Sleep 2 #give it a sec or two to finish up
}

function Copy-DownloadedFileToCachePath {
<#
.SYNOPSIS
Copy the downloaded binary (with a possibly discovered actual filename) to the cache folder as two files;
one containg discovered filename in UTF8, the other binary
#>
  param(
  [Parameter(Mandatory=$true)]
  [string]$downloadLocation,
  [Parameter(Mandatory=$true)]
  [string]$url,
  [Parameter(Mandatory=$true)]
  [string]$packageName
  )
  if(-not $env:ChocolateyInstallCachePath) {
    $env:ChocolateyInstallCachePath = [Environment]::GetEnvironmentVariable("ChocolateyInstallCachePath","Machine")
    if(-not $env:ChocolateyInstallCachePath) {
      $env:ChocolateyInstallCachePath = [Environment]::GetEnvironmentVariable("ChocolateyInstallCachePath","User")
    }
  }

  #If the $env:ChocolateyInstallCachePath is set, attempt to write installers there
  $cacheEntry = Get-CachedInstallerFileNames -PackageName $packageName -url $url
  if($cacheEntry -and $downloadLocation -and -not $cacheEntry.nameFile.StartsWith('http')) {
    $downloadFileName = [io.path]::GetFileName($downloadLocation)

    write-host -fore Yellow $url 
    $cacheDir = [IO.Path]::GetDirectoryName($cacheEntry.nameFile);
    if(-not (Test-Path $cacheDir -PathType Container)) {
      mkdir $cacheDir -errorAction SilentlyContinue | Out-Null
    }
    Set-Content $cacheEntry.nameFile -Encoding UTF8 -value $downloadFileName
    copy $downloadLocation $cacheEntry.binFile -force
    Write-Host -ForegroundColor green "Copied $downloadLocation to $($cacheEntry.binFile)"
  }
}

function Get-CachedInstallerFileNames {
<#
.SYNOPSIS
The cached files have the form of <PACKAGE_NAME>_<URL-ENCODED>_<URL-HASH>.<EXTENSION>
Where URL-ENCODED is a safe subset of url characters - ASCII alnum, hyphen, underscore and period, with one or more non-safes being replace by a single underscore, max length 128
and URL-HASH is a MD5 hash of original url in hex
EXTENSION is .txt for the file containing the actual filename, and .bin for the binary content

.OUTPUTS
PSObject, property nameFile is filename of a file containing downloaded filename in UTF8 format, binFile is filename of file with binary content
#>
    param(  [Parameter(Mandatory=$true)]
            [string]$packageName,
            [Parameter(Mandatory=$true)]
            [string]$url)
    
    $cacheBase = $env:ChocolateyInstallCachePath
    if(-not $cacheBase) {
      Write-Debug "Not using WebFile caching"
      return $null
    }
    Write-Debug "Using WebFile caching at $cacheBase"

    $urlEncoded = ($url -replace '[^A-Za-z0-9_.-]', '@') -replace '@+', '_'
    if ($urlEncoded.Length -gt 128) {
      $urlEncoded = $urlEncoded.substring(0, 128)
    }

    $md5Hasher = new-object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    $utf8Enc = new-object -TypeName System.Text.UTF8Encoding
    $hashHex = [System.BitConverter]::ToString($md5Hasher.ComputeHash($utf8Enc.GetBytes($url))) -replace '-', ''
    $cacheKey = "${PackageName}_${urlEncoded}_${hashHex}"

    Write-Debug "Using cacheKey of $cacheKey"

    if ($cacheBase.StartsWith('http')) {
      $cacheBaseName = $cacheBase
      if (-not ($cacheBaseName.EndsWith('/'))) {
        $cacheBaseName += '/'
      }
      $cacheBaseName += $cacheKey
    } else {
      $cacheBaseName = Join-Path $cacheBase $cacheKey
    }
    return New-Object PSObject -Property @{ nameFile = $cacheBaseName+".txt"; binFile = $cacheBaseName+".bin" }
}

function Handle-CachedPackageInstaller {
<#
.SYNOPSIS
Checks to see if a cached version of an installer exists for the given packagename and url.
If the cached installer file exists, it will be copied to the location specified by fileFullPath. The file name
of the installer in the cached source will be used and returned as an output paramter 

.PARAMETER fileFullPath
The full path of the desired location for the cached isntaller file (this is where the file will be copied to)
.PARAMETER actualOutputPath

.OUTPUTS
System.Bool. Returns true if a cache file exists, false if not
#>
  param(
  [Parameter(Mandatory=$true)]
  [string]$packageName,
  [Parameter(Mandatory=$true)]
  [string]$url,
  [Parameter(Mandatory=$true)]
  [string]$fileFullPath,
  [ref]$actualOutputPath
  )

  #First check if there is any local WebFile cache
  $cacheEntry = Get-CachedInstallerFileNames -packageName $packageName -url $url
  if (-not $cacheEntry) { return $false }

  $actualInstallerFullPath = $fileFullPath

  $localNameFile = $null
  $localBinFile = $null

  try {
    $originalCacheEntryUrl = $cacheEntry.binFile

    # Might refactor Get-ChocolateyWebFile into smart/cached outer layer & reusable inner part...
    if ($cacheEntry.nameFile.StartsWith('http')) {
      $localNameFile = [System.IO.Path]::GetTempFileName()
      $localBinFile = [System.IO.Path]::GetTempFileName()
      Write-Debug "Getting HTTP WebFile cache entries to $localNameFile, $localBinFile"

      try {
        $tempOutputPath = ""
        Get-WebFile -url $cacheEntry.nameFile -fileName $localNameFile -actualOutputPath ([ref]$tempOutputPath) -quiet
        $cacheEntry.nameFile = $tempOutputPath
        Get-WebFile -url $cacheEntry.binFile -fileName $localBinFile -actualOutputPath ([ref]$tempOutputPath) -quiet
        $cacheEntry.binFile = $tempOutputPath
      } catch {
        Write-Debug "No HTTP-based WebFile cache entry for $url"
        return $false;
      }

      Write-Debug "Updating cacheEntry.nameFile=$($cacheEntry.nameFile)"
      Write-Debug "Updating cacheEntry.binFile=$($cacheEntry.binFile)"
    }

    if ((Test-Path $cacheEntry.nameFile -PathType Leaf) -and (Test-Path $cacheEntry.binFile -PathType Leaf)) {
      write-Host "Using WebFile cached installer found at: $originalCacheEntryUrl"

      $actualInstallerFileName = Get-Content $cacheEntry.nameFile -Encoding UTF8
      write-Host "WebFile cached installer called: $actualInstallerFileName"

      $providedInstallerFileName = [io.path]::GetFileName($fileFullPath)
      $installerDir = ([io.path]::GetDirectoryName($fileFullPath.TrimEnd('\/ ')))

      #the provided fileFullPath is a directory
      if((Test-Path $fileFullPath -PathType Container)) {
          $actualInstallerFullPath = join-path  $fileFullPath $actualInstallerFileName

      } elseif($providedInstallerFileName -notlike "$actualInstallerFileName") {
        #The Provided file name does not match the actual installer name
        $installerDir = ([io.path]::GetDirectoryName($installerDir))
        $actualInstallerFullPath = join-path  $installerDir $actualInstallerFileName
      }

      if(-not (Test-Path $installerDir)) {
          mkdir $installerDir
      }

      Write-Debug "Using WebFile cache entry for $url"
      copy $cacheEntry.binFile $actualInstallerFullPath -force -verbose

      if($actualOutputPath) {
        $actualOutputPath.Value =  $actualInstallerFullPath
      }
      return $true;
    }
  } catch {
    Write-Debug "Error accessing WebFile cache - assuming absent/unavailable"
  } finally {
    if (($localNameFile) -and (Test-Path $localNameFile)) { Write-Debug "Removing temp file $localNameFile"; Remove-Item $localNameFile }
    if (($localBinFile) -and (Test-Path $localBinFile)) { Write-Debug "Removing temp file $localBinFile"; Remove-Item $localBinFile }
  }

  Write-Debug "No WebFile cache entry for $url"
  return $false;
}
