function Assert-DeploymentParameters {
    param($Config,[string]$Asset,$Provided,$Parameters,$Report)
    $values = @{}
    foreach ($key in $Parameters.Keys) { $values[$key] = $Parameters[$key].value }
    $ids = Get-SetupIds $Config
    if ($values.Contains('location') -and $values.location -cne $Config.location) { throw 'Asset location differs from intake.' }
    switch ($Asset) {
        { $_ -in @('account','project','network','storage') } {
            $object = switch ($Asset) { 'account' { $Config.foundryAccount }; 'project' { $Config.foundryProject }; 'network' { $Config.network }; 'storage' { $Config.storageAccount } }
            if ($object.mode -ne 'create') { throw 'Existing resources are inspected, never deployed as partial desired-state replacements.' }
            if ((Get-Digest $values.config) -ne (Get-Digest $object)) { throw 'Asset config differs from intake.' }
            $target = switch ($Asset) { 'account' { $ids.Account }; 'project' { $ids.Project }; 'network' { $ids.Vnet }; 'storage' { $ids.Storage } }
            if ($Report.state.resources[$target] -ne 'Absent') { throw 'Create target exists; reconcile its actual deployment, do not re-PUT it.' }
            if ($Asset -eq 'project') {
                if ($values.accountName -cne (Get-Names $Config).account) { throw 'Wrong project parent.' }
                $account = Get-SetupResource $ids.Account
                $projects = Get-SetupCollection "$($ids.Account)/projects"
                if ($projects.Count -or $account.kind -ne 'AIServices') { throw 'New-project creation requires the intended compatible empty account, not a multi-project retrofit.' }
            }
        }
        'workspace' {
            if ($Config.applicationInsights.mode -ne 'create' -or $Config.applicationInsights.logAnalyticsWorkspace.mode -ne 'create' -or
                $values.name -cne $Config.applicationInsights.logAnalyticsWorkspace.name -or
                $values.ingestion -cne $Config.applicationInsights.publicNetworkAccessForIngestion -or
                $values.query -cne $Config.applicationInsights.publicNetworkAccessForQuery) { throw 'Workspace parameters differ from requested new monitoring.' }
            $id = "$($ids.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($values.name)"
            if (Get-SetupResource $id -Optional) { throw 'Existing workspace must not be PUT.' }
        }
        'monitoring' {
            if ($Config.applicationInsights.mode -ne 'create' -or (Get-Digest $values.config) -ne (Get-Digest $Config.applicationInsights)) { throw 'Monitoring parameters differ from intake.' }
            if ($values.deployComponent -and (Get-SetupResource $ids.Insights -Optional)) { throw 'Existing component must not be PUT.' }
            $law = $Config.applicationInsights.logAnalyticsWorkspace
            $lawId = if ($law.mode -eq 'existing') { $law.resourceId } else { "$($ids.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($law.name)" }
            $existing = Get-SetupResource $lawId -Optional
            if ($law.mode -eq 'create' -and $values.deployWorkspace -and $existing) { throw 'Existing workspace must not be PUT; inspect and explicitly disable its declaration.' }
            if ($law.mode -eq 'existing' -and !$existing) { throw 'Supplied workspace is unavailable.' }
            if ($existing) {
                foreach ($key in @('publicNetworkAccessForIngestion','publicNetworkAccessForQuery')) {
                    if ($existing.properties[$key] -cne $Config.applicationInsights[$key]) { throw 'Workspace/component policies are incompatible; no automatic repair.' }
                }
            }
        }
        'connections' {
            if ($values.accountName -cne (Get-Names $Config).account -or $values.projectName -cne (Get-Names $Config).project -or
                $values.storageResourceId -ine $ids.Storage -or $values.applicationInsightsResourceId -ine $ids.Insights) { throw 'Connection scope/dependencies differ from intake.' }
            if ($values.deployStorageConnection -and (Get-SetupResource "$($ids.Project)/connections/$($values.storageConnectionName)" -Optional)) { throw 'Existing dataset connection must not be overwritten.' }
            if ($values.deployMonitoringConnection -and $ids.Insights -and (Get-SetupResource "$($ids.Account)/connections/$($values.monitoringConnectionName)" -Optional)) { throw 'Existing monitoring connection must not be overwritten.' }
            foreach ($kind in @('storage','monitoring')) {
                if ($kind -eq 'monitoring' -and !$ids.Insights) { continue }
                $existing = Get-CompatibleConnection $Config $kind
                $deploy = if ($kind -eq 'storage') { $values.deployStorageConnection } else { $values.deployMonitoringConnection }
                if ($deploy -and $existing) { throw 'Compatible connection already exists: explicitly reuse it with its deploy flag false.' }
                if (!$deploy -and !$existing) { throw 'Connection reuse requested but no exact compatible connection was observed.' }
            }
        }
        { $_ -in @('connectivity','monitor-connectivity') } {
            if ($values.vnetId -ine $ids.Vnet -or $values.subnetId -ine $ids.PeSubnet) { throw 'Wrong selected VNet/subnet.' }
            $allowedTargets = @($ids.Account,$ids.Storage)
            if ($Asset -eq 'connectivity' -and ($values.targetId -notin $allowedTargets -or
                ($values.targetId -ieq $ids.Account -and $values.groupId -ne 'account') -or
                ($values.targetId -ieq $ids.Storage -and $values.groupId -ne 'blob'))) { throw 'Unsupported private endpoint target/group.' }
            if ($Asset -eq 'monitor-connectivity') {
                if (!$ids.Insights -or $values.insightsId -ine $ids.Insights) { throw 'Monitoring-none/wrong component.' }
                $actual = Get-SetupResource $ids.Insights
                if ($values.workspaceId -ine $actual.properties.WorkspaceResourceId) { throw 'Monitor associations must use the actual linked LAW.' }
                $null = Assert-ResourceId $values.scopeId 'Microsoft.Insights/privateLinkScopes'
                if ($values.deployScope -and (Get-SetupResource $values.scopeId -Optional)) { throw 'Existing AMPLS policies must not be PUT.' }
            }
            $peId = "$($ids.ResourceGroup)/providers/Microsoft.Network/privateEndpoints/$($values.peName)"
            Assert-Name $values.peName '^[a-zA-Z0-9][a-zA-Z0-9_.-]+$' 2 80
            if ($values.deployEndpoint -and (Get-SetupResource $peId -Optional)) { throw 'Existing PE must not be PUT.' }
            if ($values.deployEndpoint -and $values.existingEndpointResourceId) { throw 'New PE conflicts with an existing endpoint selection.' }
            if (!$values.deployEndpoint) {
                $existingId = if ($values.existingEndpointResourceId) { $values.existingEndpointResourceId } else { $peId }
                $null = Assert-ResourceId $existingId 'Microsoft.Network/privateEndpoints'
                if ($values.deployZoneGroup -and $existingId -ine $peId) { throw 'This asset cannot add a zone group to a different-scope/name PE.' }
                $endpoint = Get-SetupResource $existingId
                $target = if ($Asset -eq 'connectivity') { $values.targetId } else { $values.scopeId }
                $group = if ($Asset -eq 'connectivity') { $values.groupId } else { 'azuremonitor' }
                $connections = @($endpoint.properties.privateLinkServiceConnections)
                if ($endpoint.properties.subnet.id -ine $ids.PeSubnet -or $connections.Count -ne 1 -or
                    $connections[0].properties.privateLinkServiceId -ine $target -or
                    (Get-Digest @($connections[0].properties.groupIds)) -ne (Get-Digest @($group))) { throw 'Existing PE target/group/subnet mismatch.' }
            }
            $requiredZones = if ($Asset -eq 'monitor-connectivity') {
                @('privatelink.monitor.azure.com','privatelink.oms.opinsights.azure.com','privatelink.ods.opinsights.azure.com','privatelink.agentsvc.azure-automation.net')
            } elseif ($values.groupId -eq 'account') {
                @('privatelink.services.ai.azure.com','privatelink.openai.azure.com','privatelink.cognitiveservices.azure.com')
            } else { @('privatelink.blob.core.windows.net') }
            if ((Get-Digest @($values.zones.name | Sort-Object)) -ne (Get-Digest @($requiredZones | Sort-Object))) { throw 'Only the target-specific DNS zone set is supported.' }
            foreach ($zone in $values.zones) {
                $null = Assert-ResourceId $zone.resourceId 'Microsoft.Network/privateDnsZones'
                if ($zone.resourceId.Split('/')[-1] -ine $zone.name) { throw 'Zone name and exact ID differ.' }
                if ($zone.deployZone -and $zone.resourceId -ine "$($ids.ResourceGroup)/providers/Microsoft.Network/privateDnsZones/$($zone.name)") { throw 'New zone scope differs from the selected RG.' }
                if ($zone.deployZone -and (Get-SetupResource $zone.resourceId -Optional)) { throw 'Supplied/existing DNS zone must not be PUT.' }
                if (!$zone.deployZone -and !(Get-SetupResource $zone.resourceId -Optional)) { throw 'Referenced DNS zone is not observable.' }
                if ($zone.deployLink -and !( $zone.resourceId -like "$($ids.ResourceGroup)/providers/Microsoft.Network/privateDnsZones/*")) { throw 'No implicit link writes to supplied DNS zones.' }
            }
        }
        'monitor-scope' {
            throw 'Use monitor-connectivity to retain explicit AMPLS/association/PE dependency scope.'
        }
    }
}
