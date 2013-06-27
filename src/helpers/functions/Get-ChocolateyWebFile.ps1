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
  [string] $url64bit = $url,
  [ref]$actualOutputPath
)
  Write-Debug "Running 'Get-ChocolateyWebFile' for $packageName with url:`'$url`', fileFullPath:`'$fileFullPath`',and url64bit:`'$url64bit`'";
  $url32bit = $url;

  #This URL is only for caching the downloaded file
  $cacheOnlyUrl = $url64bit
  $cacheOnlyBitwidth = 64
  if (Get-ProcessorBits 64) {
  	$bitWidth = 64
  	$url = $url64bit;
    $cacheOnlyUrl = $url32bit;
    $cacheOnlyBitwidth = 32
  } else { # I am just assuming that it's either 32 or 64. 
	  $bitWidth = 32
  }
  Write-Debug "CPU is $bitWidth bit"
  
  if ($url32bit -eq $url64bit) {
	$bitPackage = 32
  } else {
	$bitPackage = $bitWidth
  }
  
  #Take care of checking
  $fullInstallerPath = ""
  if(Handle-CachedPackageInstaller -packageName $packageName -bitwidth $bitwidth -fileFullPath $fileFullPath -actualOutputPath ([ref]$fullInstallerPath)) {
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
    if($url32bit -notlike $url64bit) {
        $cacheDownloadLocation = ""
        Get-WebFile -url $cacheOnlyUrl -filename $fileFullPath -actualOutputPath ([ref]$cacheDownloadLocation)
        Copy-DownloadedFileToCachePath -downloadLocation $cacheDownloadLocation -url $cacheOnlyUrl -packageName $packageName -bitwidth $cacheOnlyBitwidth
    }

  } elseif ($url.StartsWith('ftp')) {
      $downloadLocation =  $fileFullPath
      
    #if the $fileFullPath is a directory, then pull the file name fomr the source URL
    if(Test-Path $fileFullPath -PathType Container) {
        $requestUri = new-object System.Uri ($url)
        $downloadLocation = Join-Path $fileFullPath ([io.path]::GetFileName($requestUri.LocalPath))
    }
    Get-FtpFile $url $fileFullPath
  } else {
    Write-Debug "We are attempting to copy the local item `'$url`' to `'$fileFullPath`'"

    $downloadLocation =  $fileFullPath
    #if the $fileFullPath is a directory, then pull the file name fomr the source URL
    if(Test-Path $fileFullPath -PathType Container) {
        $downloadLocation = Join-Path $fileFullPath ([io.path]::GetFileName($url))
    }
    Copy-Item $url -Destination $fileFullPath -Force 
  }
    if($actualOutputPath) {
      $actualOutputPath.Value = $downloadLocation
    }
  
    Copy-DownloadedFileToCachePath -downloadLocation $downloadLocation -url $url -packageName $packageName -bitwidth $bitWidth

  
  Start-Sleep 2 #give it a sec or two to finish up
}

function Copy-DownloadedFileToCachePath {
  param(
  [Parameter(Mandatory=$true)]
  [string]$downloadLocation,
  [Parameter(Mandatory=$true)]
  [string]$url,
  [Parameter(Mandatory=$true)]
  [string]$packageName,
  [int]$bitwidth
  )
  if(-not $env:ChocolateyInstallCachePath) {
    $env:ChocolateyInstallCachePath = [Environment]::GetEnvironmentVariable("ChocolateyInstallCachePath","Machine")
    if(-not $env:ChocolateyInstallCachePath) {
      $env:ChocolateyInstallCachePath = [Environment]::GetEnvironmentVariable("ChocolateyInstallCachePath","User")
    }
  }
    #If the $env:ChocolateyInstallCachePath is set, attempt to pull installers from there
  if($env:ChocolateyInstallCachePath -and $downloadLocation) {
    $cacheFullPath = Get-PackageInstallerCachePath -url $url -PackageNameAndVersion "${packageName}" -SourceLocation $downloadLocation -bitwidth $bitwidth
    write-host -fore Yellow $url 
    $cacheDir = [IO.Path]::GetDirectoryName($cacheFullPath);
    if(-not (Test-Path $cacheDir -PathType Container)) {
      mkdir $cacheDir -errorAction SilentlyContinue
    }
    copy $downloadLocation $cacheFullPath -force
    Write-Host -ForegroundColor green "Copied $downloadLocation to $cacheFullPath"
  }

}

function Get-PackageInstallerBaseCachePath {
    param(
    [Parameter(Mandatory=$true)]
    [string]$PackageNameAndVersion)
    #$outputPath = Join-Path $env:ChocolateyInstallCachePath (join-path $PackageNameAndVersion "INSTALLER_CACHES")
    $outputpath = $env:ChocolateyInstallCachePath
    return $outputPath
}

function Get-PackageInstallerCachePath {
    param(  [Parameter(Mandatory=$true)]
            [string]$url, 
            [Parameter(Mandatory=$true)]
            [string]$PackageNameAndVersion,
            [Parameter(Mandatory=$false)]
            [string]$SourceLocation,
            [Parameter(Mandatory=$true)]
            [int]$bitwidth)

    $requestUri = new-object System.Uri ($url)
   
    $destFileName = [io.path]::GetFileName($requestUri.LocalPath)
   if($SourceLocation) {
    $destFileName = [io.path]::GetFileName($SourceLocation)
   }

    $subPath =  "${PackageNameAndVersion}__x${bitwidth}__${destFileName}"

    $subPath = join-path (Get-PackageInstallerBaseCachePath $PackageNameAndVersion) $subPath
    $outputPath =  $subPath
    
    return $outputPath
}

function Get-CachedInstallerPath {
    param(  [Parameter(Mandatory=$true)]
            [string]$PackageNameAndVersion,
            [int]$bitwidth)
    
    if(-not $env:ChocolateyInstallCachePath) { return $null }
    #The web downloader creates *.ignore files
    $installerPath = gci $env:ChocolateyInstallCachePath -filter "${PackageNameAndVersion}__x${bitwidth}__*" | where { $_.FullName -inotlike "*.ignore"}
   
    return $installerPath.FullName

}

function Get-ActualInstallerFileName {
<#
.SYNOPSIS
The cached files have the form of <PACKAGE_NAME>__x<BITWIDTH>__<ACTUALFILENAME>

#>
    param([Parameter(Mandatory=$true)]
            [string]$CacheFilePath)

    $filename = [io.path]::GetFileName($CacheFilePath)
    $parts = $filename -isplit "__"
    if(-not $parts -or $parts.Length -lt 3) {
        write-warning "Expected file name to formatted like: <PACKAGE_NAME>__x<BITWIDTH>__<ACTUALFILENAME>, actual file name was: $filename"
    }
    return $parts[2]
}

function Handle-CachedPackageInstaller {
<#
.SYNOPSIS
Checks to see if a caches version of an installer exists for the given packagename and bitwidth (32 or 64).  
If the cached installer file exists, it will be copied to the location specified by fileFullPath.  

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
  [int]$bitwidth,
  [Parameter(Mandatory=$true)]
  [string]$fileFullPath,
  [ref]$actualOutputPath
  )
  #first check if there is a local cache for the installer
  $cacheFullPath = Get-CachedInstallerPath -PackageNameAndVersion $packageName -bitwidth $bitwidth
 
  if($cacheFullPath -and (Test-Path $cacheFullPath -PathType Leaf)) {
    write-Host "Using cached installer found at: $cacheFullPath"

    #Copy the cached version of the file to the requested location if different
    $cachedInstallerDir = [io.path]::GetDirectoryName($cacheFullPath)

    $actualInstallerFileName = join-path $fileFullPath (Get-ActualInstallerFileName $cacheFullPath)

    copy $cacheFullPath  $actualInstallerFileName -force -verbose
    
    if($actualOutputPath) {
        $actualOutputPath.Value = $actualInstallerFileName
    }

    return $true;
  }

  return $false;
}