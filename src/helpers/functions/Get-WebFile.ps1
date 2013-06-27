# http://poshcode.org/417
## Get-WebFile (aka wget for PowerShell)
##############################################################################################################
## Downloads a file or page from the web
## History:
## v3.6 - Add -Passthru switch to output TEXT files
## v3.5 - Add -Quiet switch to turn off the progress reports ...
## v3.4 - Add progress report for files which don't report size
## v3.3 - Add progress report for files which report their size
## v3.2 - Use the pure Stream object because StreamWriter is based on TextWriter:
##        it was messing up binary files, and making mistakes with extended characters in text
## v3.1 - Unwrap the filename when it has quotes around it
## v3   - rewritten completely using HttpWebRequest + HttpWebResponse to figure out the file name, if possible
## v2   - adds a ton of parsing to make the output pretty
##        added measuring the scripts involved in the command, (uses Tokenizer)
##############################################################################################################
function Get-WebFile {
<#
.SYNOPSIS
Downloads a file from the internet.

.DESCRIPTION
This will download a file from a url, tracking with a progress bar. 
It returns the filepath to the downloaded file when it is complete.
Will make the best attempt to retain the original file name

.PARAMETER PackageName
The name of the package we want to download - this is arbitrary, call it whatever you want.
It's recommended you call it the same as your nuget package id.

.PARAMETER FileName
This is the full path of the resulting file name.
If this is just a directory path, then the file name will be obtained automatically.

.PARAMETER Url
This is the url to download the file from. 

.PARAMETER FileNamePrefix
An optional prefix to prepend the file name with

.PARAMETER ActualOutputPath
An optional output parameter that contains the actual full path of where the file was written to

.EXAMPLE
Get-WebFile -filepath 'C:\somepath' -url 'http://acme.com/archive/UltimateApp.msi'

Description

-----------

Will download the URL content to a file located at 'C:\somepath\UltimateApp.msi

.EXAMPLE
Get-WebFile -filepath 'C:\somepath' -url 'http://acme.com/archive/?Redir=1&File=A58BF -fileNamePrefix 'UltimateApp.1.0.4__'

Description

-----------

The actual filename cannot be known until the response from the server returns.
In this case the FileName from the response is UltimateApp_x64.msi.
Will download the URL content to a file located at 'C:\somepath\UltimateApp.1.0.4__UltimateApp_x64.msi

.NOTES
This helper reduces the number of lines one would have to write to download a file to 1 line.
There is no error handling built into this method.

.LINK
Install-ChocolateyPackage
#>
param(
  $url = '', #(Read-Host "The URL to download"),
  $fileName = $null,
  $userAgent = 'chocolatey command line',
  $fileNamePrefix,
  [ref]$actualOutputPath,
  [switch]$Passthru,
  [switch]$quiet
)
  Write-Debug "Running 'Get-WebFile' for $fileName with url:`'$url`', userAgent: `'$userAgent`' ";
  #if ($url -eq '' return)

  #Default the output directory to the current directory
  $outputDir = (Get-Location -PSProvider "FileSystem")
  #If the filename contains a directory path, use that for the outputdir value
  if(Split-path $fileName) {
    $outputDir = [io.path]::GetDirectoryName($fileName)
  }

  $req = [System.Net.HttpWebRequest]::Create($url);
  #to check if a proxy is required
  $webclient = new-object System.Net.WebClient
  if (!$webclient.Proxy.IsBypassed($url))
  {
    $creds = [net.CredentialCache]::DefaultCredentials
    if ($creds -eq $null) {
      Write-Debug "Default credentials were null. Attempting backup method"
      $cred = get-credential
      $creds = $cred.GetNetworkCredential();
    }
    $proxyaddress = $webclient.Proxy.GetProxy($url).Authority
    Write-host "Using this proxyserver: $proxyaddress"
    $proxy = New-Object System.Net.WebProxy($proxyaddress)
    $proxy.credentials = $creds
    $req.proxy = $proxy
  }
 
  #http://stackoverflow.com/questions/518181/too-many-automatic-redirections-were-attempted-error-message-when-using-a-httpw
  $req.CookieContainer = New-Object System.Net.CookieContainer
  if ($userAgent -ne $null) {
    Write-Debug "Setting the UserAgent to `'$userAgent`'"
    $req.UserAgent = $userAgent
  }
  $res = $req.GetResponse();
  

  
  #The $fileName is just a file name, no directory component
  if($fileName -and !(Split-Path $fileName)) {
    $fileName = Join-Path $outputDir $fileName
  }
  #The filename is empty or the filename is present and it is a directory ("Container")
  elseif((!$Passthru -and ($fileName -eq $null)) -or (($fileName) -and (Test-Path $fileName -PathType Container)))
  {
    $outputDir = $fileName
   # $outputDir = [IO.Path]::GetDirectoryName($fileName)
   # if(-not (Test-Path $outputDir -PathType Container)) {
    #  mkdir $outputDir -errorAction SilentlyContinue
   # }
    
    #get the file name from the Content-Disposition header (rarely present)
    [string]$fileName = ([regex]'(?i)filename=(.*)$').Match( $res.Headers["Content-Disposition"] ).Groups[1].Value
    $fileName = $fileName.trim("\/""'")
    if(!$fileName) {
        #Get the file name from the response's URI localpath
       $fileName = [System.IO.Path]::GetFileName($res.ResponseUri.LocalPath)
       $fileName = $fileName.trim("\/")
       if(!$fileName) {
         #Last ditch effort to get a file name before resorting to prompting
         $uri = new-object  System.Uri ($url)
         $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
         if(!$fileName) {
           $fileName = Read-Host "Please provide a file name"
         }
       }
       $fileName = $fileName.trim("\/")
       if(!([IO.FileInfo]$fileName).Extension) {
          $fileName = $fileName + "." + $res.ContentType.Split(";")[0].Split("/")[1]
       }
    }
    $fileName = Join-Path $outputDir $fileName
  }
  if($Passthru) {
    $encoding = [System.Text.Encoding]::GetEncoding( $res.CharacterSet )
    [string]$output = ""
  }

  #If a file name prefix has been provided, prepend the name of the file
  if($fileNamePrefix) {
     $fileName = join-path ([io.path]::GetDirectoryName($fileName)) ($fileNamePrefix  + [io.path]::GetFileName($fileName))
  }
  
  #Set the value of the actual output path
  if($actualOutputPath) {
    $actualOutputPath.Value = $fileName
  }

  Write-Warning $fileName
  #return
  Write-Debug "Downloading file from $url to $fileName"

  if($res.StatusCode -eq 200) {
    [long]$goal = $res.ContentLength
    $reader = $res.GetResponseStream()
    if($fileName) {
       $writer = new-object System.IO.FileStream $fileName, "Create"
    }
    [byte[]]$buffer = new-object byte[] 1048576
    [long]$total = [long]$count = [long]$iterLoop =0
    do
    {
       $count = $reader.Read($buffer, 0, $buffer.Length);
       if($fileName) {
          $writer.Write($buffer, 0, $count);
       }
       if($Passthru){
          $output += $encoding.GetString($buffer,0,$count)
       } elseif(!$quiet) {
          $total += $count
          if($goal -gt 0 -and ++$iterLoop%10 -eq 0) {
             Write-Progress "Downloading $url to $fileName" "Saving $total of $goal" -id 0 -percentComplete (($total/$goal)*100) 
          }
          if ($total -eq $goal) {
            Write-Progress "Completed download of $url." "Completed a total of $total bytes of $fileName" -id 0 -Completed 
          }
       }
    } while ($count -gt 0)
   
    $reader.Close()
    if($fileName) {
       $writer.Flush()
       $writer.Close()
    }
    if($Passthru){
       $output
    }
  }
  $res.Close();
}
