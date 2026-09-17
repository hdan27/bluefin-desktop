podman save -o /var/home/dan/BLUEFIN/finpilot-stable.tar localhost/finpilot:stable
sudo bootc switch --transport oci-archive /var/home/dan/BLUEFIN/finpilot-stable.tar
systemctl reboot
