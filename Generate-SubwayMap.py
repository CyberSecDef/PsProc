#!/usr/bin/env python3
"""
Generate a subway map visualization of the PsProc codebase structure.
This script analyzes the PowerShell module and creates a visual representation
as a subway/metro map showing the hierarchical relationships.
"""

import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyBboxPatch, Circle
import numpy as np
import argparse
import sys
from typing import List, Tuple, Dict

# Define the codebase structure based on analysis
CODEBASE_STRUCTURE = {
    'Root': {
        'files': ['cpuinfo', 'meminfo', 'version', 'uptime', 'loadavg', 'stat', 
                  'mounts', 'cmdline', 'filesystems', 'swaps', 'partitions', 'modules'],
        'dirs': {
            'net': ['dev', 'route', 'arp', 'tcp', 'udp'],
            'sys/kernel': ['hostname', 'ostype', 'osrelease', 'version'],
            'devices': ['block', 'character'],
            'self': ['cmdline', 'status', 'stat', 'environ'],
            '[PID]': ['cmdline', 'status', 'stat', 'environ', 'maps']
        }
    }
}

# Subway line colors (metro-style)
COLORS = {
    'system_info': '#E63946',      # Red - System Information Line
    'network': '#2A9D8F',          # Teal - Network Line  
    'config': '#F4A261',           # Orange - Configuration Line
    'devices': '#E76F51',          # Coral - Devices Line
    'processes': '#264653',        # Dark Blue - Process Line
    'storage': '#8338EC',          # Purple - Storage Line
}

class SubwayMapGenerator:
    def __init__(self, width=20, height=16):
        self.fig, self.ax = plt.subplots(figsize=(width, height))
        self.ax.set_xlim(0, 100)
        self.ax.set_ylim(0, 100)
        self.ax.axis('off')
        self.stations = {}
        
    def draw_station(self, x, y, name, color, is_interchange=False, size=0.8):
        """Draw a station marker"""
        if is_interchange:
            # Interchange station - larger with white ring
            circle = Circle((x, y), size*1.2, color='white', zorder=3)
            self.ax.add_patch(circle)
            circle = Circle((x, y), size, color=color, zorder=4)
            self.ax.add_patch(circle)
        else:
            # Regular station
            circle = Circle((x, y), size, color=color, zorder=3)
            self.ax.add_patch(circle)
            
        self.stations[name] = (x, y)
        
    def draw_line(self, points, color, linewidth=4, style='-'):
        """Draw a subway line through multiple points"""
        if len(points) < 2:
            return
        xs, ys = zip(*points)
        self.ax.plot(xs, ys, color=color, linewidth=linewidth, 
                    linestyle=style, zorder=2, solid_capstyle='round')
        
    def add_label(self, x, y, text, fontsize=9, ha='left', va='center', 
                  offset_x=2, offset_y=0, bbox_style=None, fontweight='normal'):
        """Add a text label"""
        if bbox_style:
            self.ax.text(x + offset_x, y + offset_y, text, 
                        fontsize=fontsize, ha=ha, va=va, zorder=5,
                        fontweight=fontweight,
                        bbox=dict(boxstyle='round,pad=0.3', 
                                facecolor='white', edgecolor='gray', alpha=0.9))
        else:
            self.ax.text(x + offset_x, y + offset_y, text, 
                        fontsize=fontsize, ha=ha, va=va, zorder=5,
                        fontweight=fontweight)
    
    def draw_legend(self):
        """Draw the map legend"""
        legend_x = 5
        legend_y = 8
        
        # Title
        self.ax.text(legend_x, legend_y + 18, 'PsProc Filesystem', 
                    fontsize=24, fontweight='bold', zorder=5)
        self.ax.text(legend_x, legend_y + 15, 'Subway Map', 
                    fontsize=20, fontweight='bold', zorder=5)
        
        # Line legend
        lines = [
            ('System Info Line', COLORS['system_info']),
            ('Network Line', COLORS['network']),
            ('Configuration Line', COLORS['config']),
            ('Devices Line', COLORS['devices']),
            ('Process Line', COLORS['processes']),
            ('Storage Line', COLORS['storage']),
        ]
        
        for i, (label, color) in enumerate(lines):
            y = legend_y - i * 2
            self.ax.plot([legend_x, legend_x + 4], [y, y], 
                        color=color, linewidth=4, zorder=2)
            self.ax.text(legend_x + 5, y, label, fontsize=10, 
                        va='center', zorder=5)
    
    def generate_map(self):
        """Generate the complete subway map"""
        
        # Central hub - ProcRoot
        hub_x, hub_y = 50, 50
        self.draw_station(hub_x, hub_y, 'proc:/', 'black', is_interchange=True, size=1.5)
        self.add_label(hub_x, hub_y, 'proc:/', fontsize=14, fontweight='bold',
                      offset_x=0, offset_y=-3, ha='center', bbox_style=True)
        
        # System Information Line (Red) - Vertical going up
        sys_info_stations = [
            (hub_x, hub_y),
            (hub_x, hub_y + 8, 'cpuinfo'),
            (hub_x, hub_y + 14, 'meminfo'),
            (hub_x, hub_y + 20, 'version'),
            (hub_x, hub_y + 26, 'uptime'),
            (hub_x, hub_y + 32, 'loadavg'),
            (hub_x, hub_y + 38, 'stat'),
        ]
        self.draw_line([s[:2] for s in sys_info_stations], COLORS['system_info'])
        for station in sys_info_stations[1:]:
            self.draw_station(station[0], station[1], station[2], COLORS['system_info'])
            self.add_label(station[0], station[1], station[2], offset_x=3)
        
        # Network Line (Teal) - Diagonal to upper right
        net_hub_x, net_hub_y = hub_x + 20, hub_y + 20
        self.draw_line([(hub_x, hub_y), (net_hub_x, net_hub_y)], COLORS['network'])
        self.draw_station(net_hub_x, net_hub_y, 'net/', COLORS['network'], is_interchange=True)
        self.add_label(net_hub_x, net_hub_y, 'net/', fontsize=11, fontweight='bold',
                      offset_x=0, offset_y=2, ha='center', bbox_style=True)
        
        # Network sub-stations branching out
        net_stations = [
            (net_hub_x + 8, net_hub_y + 4, 'dev'),
            (net_hub_x + 12, net_hub_y + 8, 'route'),
            (net_hub_x + 16, net_hub_y + 4, 'arp'),
            (net_hub_x + 20, net_hub_y, 'tcp'),
            (net_hub_x + 20, net_hub_y - 4, 'udp'),
        ]
        for i, station in enumerate(net_stations):
            self.draw_line([(net_hub_x, net_hub_y), (station[0], station[1])], COLORS['network'], linewidth=3)
            self.draw_station(station[0], station[1], f'net/{station[2]}', COLORS['network'], size=0.6)
            self.add_label(station[0], station[1], station[2], fontsize=8, offset_x=2)
        
        # Configuration Line (Orange) - Diagonal to lower right
        sys_hub_x, sys_hub_y = hub_x + 20, hub_y - 20
        self.draw_line([(hub_x, hub_y), (sys_hub_x, sys_hub_y)], COLORS['config'])
        self.draw_station(sys_hub_x, sys_hub_y, 'sys/', COLORS['config'], is_interchange=True)
        self.add_label(sys_hub_x, sys_hub_y, 'sys/', fontsize=11, fontweight='bold',
                      offset_x=0, offset_y=-2.5, ha='center', bbox_style=True)
        
        # sys/kernel sub-stations
        kernel_x, kernel_y = sys_hub_x + 10, sys_hub_y - 8
        self.draw_line([(sys_hub_x, sys_hub_y), (kernel_x, kernel_y)], COLORS['config'])
        self.draw_station(kernel_x, kernel_y, 'sys/kernel/', COLORS['config'], is_interchange=True, size=0.9)
        self.add_label(kernel_x, kernel_y, 'kernel/', fontsize=10, fontweight='bold',
                      offset_x=0, offset_y=-2, ha='center')
        
        kernel_stations = [
            (kernel_x + 6, kernel_y - 4, 'hostname'),
            (kernel_x + 10, kernel_y - 6, 'ostype'),
            (kernel_x + 14, kernel_y - 4, 'osrelease'),
            (kernel_x + 18, kernel_y, 'version'),
        ]
        for station in kernel_stations:
            self.draw_line([(kernel_x, kernel_y), (station[0], station[1])], COLORS['config'], linewidth=3)
            self.draw_station(station[0], station[1], f'kernel/{station[2]}', COLORS['config'], size=0.6)
            self.add_label(station[0], station[1], station[2], fontsize=8, offset_x=2)
        
        # Devices Line (Coral) - Horizontal to right
        dev_hub_x, dev_hub_y = hub_x + 22, hub_y
        self.draw_line([(hub_x, hub_y), (dev_hub_x, dev_hub_y)], COLORS['devices'])
        self.draw_station(dev_hub_x, dev_hub_y, 'devices/', COLORS['devices'], is_interchange=True)
        self.add_label(dev_hub_x, dev_hub_y, 'devices/', fontsize=11, fontweight='bold',
                      offset_x=0, offset_y=2, ha='center', bbox_style=True)
        
        # Device sub-stations
        dev_stations = [
            (dev_hub_x + 8, dev_hub_y + 3, 'block'),
            (dev_hub_x + 8, dev_hub_y - 3, 'character'),
        ]
        for station in dev_stations:
            self.draw_line([(dev_hub_x, dev_hub_y), (station[0], station[1])], COLORS['devices'], linewidth=3)
            self.draw_station(station[0], station[1], f'devices/{station[2]}', COLORS['devices'], size=0.6)
            self.add_label(station[0], station[1], station[2], fontsize=8, offset_x=2)
        
        # Process Line (Dark Blue) - Diagonal to upper left
        proc_hub_x, proc_hub_y = hub_x - 20, hub_y + 20
        self.draw_line([(hub_x, hub_y), (proc_hub_x, proc_hub_y)], COLORS['processes'])
        self.draw_station(proc_hub_x, proc_hub_y, 'self/', COLORS['processes'], is_interchange=True)
        self.add_label(proc_hub_x, proc_hub_y, 'self/', fontsize=11, fontweight='bold',
                      offset_x=0, offset_y=2, ha='center', bbox_style=True)
        
        # self sub-stations
        self_stations = [
            (proc_hub_x - 8, proc_hub_y + 4, 'cmdline'),
            (proc_hub_x - 12, proc_hub_y + 8, 'status'),
            (proc_hub_x - 16, proc_hub_y + 4, 'stat'),
            (proc_hub_x - 18, proc_hub_y, 'environ'),
        ]
        for station in self_stations:
            self.draw_line([(proc_hub_x, proc_hub_y), (station[0], station[1])], COLORS['processes'], linewidth=3)
            self.draw_station(station[0], station[1], f'self/{station[2]}', COLORS['processes'], size=0.6)
            self.add_label(station[0], station[1], station[2], fontsize=8, offset_x=-2, ha='right')
        
        # [PID] branch
        pid_x, pid_y = proc_hub_x, proc_hub_y + 12
        self.draw_line([(proc_hub_x, proc_hub_y), (pid_x, pid_y)], COLORS['processes'])
        self.draw_station(pid_x, pid_y, '[PID]/', COLORS['processes'], is_interchange=True, size=0.9)
        self.add_label(pid_x, pid_y, '[PID]/', fontsize=10, fontweight='bold',
                      offset_x=0, offset_y=2, ha='center')
        
        pid_stations = [
            (pid_x - 6, pid_y + 4, 'cmdline'),
            (pid_x - 10, pid_y + 6, 'status'),
            (pid_x - 14, pid_y + 4, 'stat'),
            (pid_x - 16, pid_y, 'environ'),
            (pid_x - 16, pid_y - 4, 'maps'),
        ]
        for station in pid_stations:
            self.draw_line([(pid_x, pid_y), (station[0], station[1])], COLORS['processes'], linewidth=3)
            self.draw_station(station[0], station[1], f'[PID]/{station[2]}', COLORS['processes'], size=0.6)
            self.add_label(station[0], station[1], station[2], fontsize=8, offset_x=-2, ha='right')
        
        # Storage Line (Purple) - Diagonal to lower left
        storage_stations = [
            (hub_x, hub_y),
            (hub_x - 8, hub_y - 8, 'mounts'),
            (hub_x - 14, hub_y - 14, 'swaps'),
            (hub_x - 20, hub_y - 20, 'partitions'),
            (hub_x - 26, hub_y - 26, 'filesystems'),
        ]
        self.draw_line([s[:2] for s in storage_stations], COLORS['storage'])
        for station in storage_stations[1:]:
            self.draw_station(station[0], station[1], station[2], COLORS['storage'])
            self.add_label(station[0], station[1], station[2], offset_x=-2, ha='right')
        
        # Additional files - modules and cmdline as single stations
        self.draw_line([(hub_x, hub_y), (hub_x - 12, hub_y)], COLORS['system_info'], linewidth=3)
        self.draw_station(hub_x - 12, hub_y, 'modules', COLORS['system_info'], size=0.6)
        self.add_label(hub_x - 12, hub_y, 'modules', fontsize=8, offset_x=-2, ha='right')
        
        self.draw_line([(hub_x, hub_y), (hub_x, hub_y - 8)], COLORS['system_info'], linewidth=3)
        self.draw_station(hub_x, hub_y - 8, 'cmdline', COLORS['system_info'], size=0.6)
        self.add_label(hub_x, hub_y - 8, 'cmdline', fontsize=8, offset_y=-2, ha='center')
        
        # Draw legend
        self.draw_legend()
        
        # Add footer info
        self.ax.text(50, 2, 'PowerShell proc: Drive Filesystem Structure', 
                    fontsize=10, ha='center', style='italic', color='gray')
        self.ax.text(50, 0.5, 'Generated by Generate-SubwayMap.py', 
                    fontsize=8, ha='center', color='gray')
        
        # Set background color
        self.fig.patch.set_facecolor('#f5f5f5')
        self.ax.set_facecolor('white')
        
    def save(self, filename='codebase-subway-map.png', dpi=300):
        """Save the map to a file"""
        plt.tight_layout()
        plt.savefig(filename, dpi=dpi, bbox_inches='tight', facecolor='#f5f5f5')
        print(f"Subway map saved to: {filename}")
        
    def show(self):
        """Display the map"""
        plt.show()


def main():
    """Main function to generate the subway map"""
    parser = argparse.ArgumentParser(
        description='Generate a subway map visualization of the PsProc codebase structure'
    )
    parser.add_argument(
        '-o', '--output',
        default='codebase-subway-map.png',
        help='Output filename for the subway map (default: codebase-subway-map.png)'
    )
    parser.add_argument(
        '--dpi',
        type=int,
        default=300,
        help='DPI for the output image (default: 300)'
    )
    
    args = parser.parse_args()
    
    print("Generating PsProc Codebase Subway Map...")
    
    generator = SubwayMapGenerator()
    generator.generate_map()
    generator.save(filename=args.output, dpi=args.dpi)
    
    print(f"Done! Map saved as '{args.output}'")


if __name__ == '__main__':
    main()
