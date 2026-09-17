podman save -o /tmp/finpilot-stable.tar localhost/finpilot:stable
sudo podman load -i /tmp/finpilot-stable.tar
sudo bootc switch --transport containers-storage localhost/finpilot:stable
#systemctl reboot
