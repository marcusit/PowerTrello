﻿#Requires -Version 4
Set-StrictMode -Version Latest

$baseUrl = 'https://api.trello.com/1'
$ProjectName = 'PowerTrello'

function Request-TrelloAccessToken
{
	[CmdletBinding()]
	[OutputType('System.String')]
	param
	(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ApiKey,
		
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$Scope = 'read,write',
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$ApplicationName = $ProjectName,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[int]$AuthTimeout = 30
		
	)
	
	$ErrorActionPreference = 'Stop'
	try
	{
		$httpParams = @{
			'key' = $apiKey
			'expiration' = 'never'
			'scope' = $Scope
			'response_type' = 'token'
			'name' = $ApplicationName
			'return_url' = 'https://trello.com'
		}
		
		$keyValues = @()
		$httpParams.GetEnumerator() | sort Name | foreach {
			$keyValues += "$($_.Key)=$($_.Value)"
		}
		
		$keyValueString = $keyValues -join '&'
		$authUri = "$baseUrl/authorize?$keyValueString"
		
		$IE = New-Object -ComObject InternetExplorer.Application
		$null = $IE.Navigate($authUri)
		$null = $IE.Visible = $true
		
		$timer = [System.Diagnostics.Stopwatch]::StartNew()
		while (($IE.LocationUrl -notmatch '^https://trello.com/token=') -and ($timer.Elapsed.TotalSeconds -lt $AuthTimeout))
		{
			Start-Sleep -Seconds 1
		}
		$timer.Stop()
		
		if ($timer.Elapsed.TotalSeconds -ge $AuthTimeout)
		{
			throw 'Timeout waiting for user authorization.'
		}
		
		[regex]::Match($IE.LocationURL, 'token=(.+)').Groups[1].Value
		
	}
	catch
	{
		Write-Error $_.Exception.Message
	}
	finally
	{
		$null = $IE.Quit()	
	}
}

function Get-TrelloConfiguration
{
	[CmdletBinding()]
	param
	(
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$RegistryKeyPath = "HKCU:\Software\$ProjectName"
	)
	
	$ErrorActionPreference = 'Stop'
	try
	{
		if (-not (Test-Path -Path $RegistryKeyPath))
		{
			Write-Verbose "No $ProjectName configuration found in registry"
		}
		else
		{
			$keyValues = Get-ItemProperty -Path $RegistryKeyPath
			$global:trelloConfig = [pscustomobject]@{
				'APIKey' = $keyValues.APIKey;
				'AccessToken' = $keyValues.AccessToken
				'String' = "key=$($keyValues.APIKey)&token=$($keyValues.AccessToken)"	
			}
			$trelloConfig
		}
	}
	catch
	{
		Write-Error $_.Exception.Message
	}
}

function Set-TrelloConfiguration
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$ApiKey,
	
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$AccessToken,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$RegistryKeyPath = "HKCU:\Software\$ProjectName"
	)
		
	if (-not (Test-Path -Path $RegistryKeyPath))
	{
		New-Item -Path ($RegistryKeyPath | Split-Path -Parent) -Name ($RegistryKeyPath | Split-Path -Leaf) | Out-Null
	}
	
	$values = 'APIKey', 'AccessToken'
	foreach ($val in $values)
	{
		if ((Get-Item $RegistryKeyPath).GetValue($val))
		{
			Write-Verbose "'$RegistryKeyPath\$val' already exists. Skipping."
		}
		else
		{
			Write-Verbose "Creating $RegistryKeyPath\$val"
			New-ItemProperty $RegistryKeyPath -Name $val -Value ((Get-Variable $val).Value) -Force | Out-Null
		}
	}
}

function Get-TrelloBoard
{
	[CmdletBinding(DefaultParameterSetName = 'None')]
	param
	(
		[Parameter(ParameterSetName = 'ByName')]
		[ValidateNotNullOrEmpty()]
		[string]$Name,
		
		[Parameter(ParameterSetName = 'ById')]
		[ValidateNotNullOrEmpty()]
		[string]$Id,
	
		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[switch]$IncludeClosedBoards
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try
		{
			$getParams = @{
				'key' = $trelloConfig.APIKey
				'token' = $trelloConfig.AccessToken
			}
			if (-not $IncludeClosedBoards.IsPresent)
			{
				$getParams.filter = 'open'
			}
			
			$keyValues = @()
			$getParams.GetEnumerator() | foreach {
				$keyValues += "$($_.Key)=$($_.Value)"
			}
			
			$paramString = $keyValues -join '&'
			
			switch ($PSCmdlet.ParameterSetName)
			{
				'ByName' {
					$uri = "$baseUrl/members/me/boards"
					$boards = Invoke-RestMethod -Uri ('{0}?{1}' -f $uri, $paramString)
					$boards | where { $_.name -eq $Name }
				}
				'ById' {
					$uri = "$baseUrl/boards/$Id"
					Invoke-RestMethod -Uri ('{0}?{1}' -f $uri, $paramString)
				}
				default
				{
					$uri = "$baseUrl/members/me/boards"
					Invoke-RestMethod -Uri ('{0}?{1}' -f $uri, $paramString)
				}
			}
		}
		catch
		{
			Write-Error $_.Exception.Message
		}
	}
}

function Get-TrelloBoardList
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory,ValueFromPipelineByPropertyName)]
		[ValidateNotNullOrEmpty()]
		[Alias('Id')]
		[string]$BoardId
		
	)
	begin
	{
		$ErrorActionPreference = 'Stop'
	}
	process
	{
		try
		{
			Invoke-RestMethod -Uri "$baseUrl/boards/$BoardId/lists?$($trelloConfig.String)"
		}
		catch
		{
			Write-Error $_.Exception.Message
		}
	}
}

function Get-TrelloCard
{
	[CmdletBinding(DefaultParameterSetName = 'None')]
	param
	(
		[Parameter(Mandatory, ValueFromPipeline)]
		[ValidateNotNullOrEmpty()]
		[object]$Board,
		
		[Parameter(ParameterSetName = 'Label')]
		[ValidateNotNullOrEmpty()]
		[string]$Label,
	
		[Parameter(ParameterSetName = 'Due')]
		[ValidateNotNullOrEmpty()]
		[ValidateSet('Today','Tomorrow','In7Days','In14Days')]
		[string]$Due
		
		
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try
		{
			$cards = Invoke-RestMethod -Uri "$baseUrl/boards/$($Board.Id)/cards?$($trelloConfig.String)"
			if ($PSBoundParameters.ContainsKey('Label')) {
				$cards | where { if (($_.labels) -and $_.labels.Name -contains $Label) { $true } }
			}
			elseif ($PSBoundParameters.ContainsKey('Due'))
			{
				$cards
			}
		}
		catch
		{
			Write-Error $_.Exception.Message
		}
	}
}

function Get-TrelloCardLabel
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory, ValueFromPipeline)]
		[ValidateNotNullOrEmpty()]
		[object]$Board
	)
	begin {
		$ErrorActionPreference = 'Stop'
	}
	process {
		try
		{
			$uri = "$baseUrl/boards/{0}/labels?{1}" -f $BoardId, $trelloConfig.String
			Invoke-RestMethod -Uri $uri
		}
		catch
		{
			Write-Error $_.Exception.Message
		}
	}
}