# ADIN2111 Dual-Port Ethernet Switch/PHY Emulation
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

softmmu_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))

specific_ss.add(when: 'CONFIG_ADIN2111', if_true: files(
  'adin2111.c',
))

# Add to the network device list
net_devices = []
net_devices += {'name': 'adin2111', 'config': 'CONFIG_ADIN2111'}

foreach device : net_devices
  config_devices += {device['config']: 'y'}
endforeach