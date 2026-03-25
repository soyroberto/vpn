@description('Region for all resources (Singapore)')
param location string = 'southeastasia'  // Singapore region code

@description('Resource group name')
param resourceGroupName string = 'rg-vpn-singapore'

@description('VM admin username')
param adminUsername string = 'vpnadmin'

@description('SSH public key for authentication')
@secure()
param sshPublicKey string

@description('VM size (B1ls is cheapest, ~$4/month)')
param vmSize string = 'Standard_B1ls'

@description('VPN server name prefix')
param vpnServerName string = 'vpnserver-sg'

@description('WireGuard port')
param wireguardPort int = 51820

@description('Virtual Network address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix')
param subnetAddressPrefix string = '10.0.0.0/24'

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: '${vpnServerName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
  }
}

// Public IP
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: '${vpnServerName}-pip'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Network Security Group
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: '${vpnServerName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'  // Consider restricting to your IP in production
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'WireGuard'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: string(wireguardPort)
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Network Interface
resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: '${vpnServerName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// Cloud-init script to install WireGuard
var cloudInitScript = '''
#!/bin/bash
# Update system
apt-get update
apt-get upgrade -y

# Install WireGuard
apt-get install -y wireguard resolvconf

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure firewall (UFW)
ufw allow 22/tcp
ufw allow ${wireguardPort}/udp
ufw --force enable

# Generate server keys
wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

# Create server configuration
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $(cat /etc/wireguard/privatekey)
Address = 10.0.1.1/24
ListenPort = ${wireguardPort}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Display server information
echo "========================================="
echo "WireGuard Server Public Key:"
cat /etc/wireguard/publickey
echo "========================================="
echo "Server private IP: 10.0.1.1"
echo "Server public IP: $(curl -s ifconfig.me)"
echo "WireGuard Port: ${wireguardPort}"
echo "========================================="
'''

// Linux VM
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vpnServerName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: vpnServerName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: base64(cloudInitScript)
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// Outputs
output 'resourceGroup' string = resourceGroupName
output 'location' string = location
output 'vmName' string = vm.name
output 'publicIpAddress' string = publicIp.properties.ipAddress
output 'wireguardPort' int = wireguardPort
output 'sshCommand' string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output 'vnetName' string = vnet.name
