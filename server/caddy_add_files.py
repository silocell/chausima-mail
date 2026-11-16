import sys; p=sys.argv[1]; s=open(p).read()
if 'chausima-mail-files' in s: print("Caddy: already done"); sys.exit()
add='''\t# chausima-mail-files
\t@cmfiles path /manifest.webmanifest /sw.js /icon-192.png /icon-512.png /icon.svg
\thandle @cmfiles {
\t\troot * /srv/chausima-mail
\t\theader /sw.js Cache-Control "no-cache"
\t\tfile_server
\t}
\thandle /logo {
\t\troot * /srv/chausima-mail
\t\trewrite * /logo.svg
\t\theader Cache-Control "no-cache"
\t\tfile_server
\t}
\t@icon path /favicon.ico /admin/favicon.ico
\thandle @icon {
\t\troot * /srv/chausima-mail
\t\trewrite * /icon.svg
\t\tfile_server
\t}
'''
a='\t@page path / /index.html\n'
assert s.count(a)==1; s=s.replace(a, add+a); open(p,'w').write(s); print("Caddy: app files, logo and icon added")
