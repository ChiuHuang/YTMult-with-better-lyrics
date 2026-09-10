import sys
import re

file_path = sys.argv[1]
with open(file_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = []
first_y_seen = False

for line in lines:
    if line.startswith('pick ') and ' y\n' in line:
        if not first_y_seen:
            new_lines.append(line.replace('pick ', 'reword '))
            first_y_seen = True
        else:
            new_lines.append(line.replace('pick ', 'squash '))
    else:
        new_lines.append(line)

with open(file_path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)
