# nginx config for the in-cluster Bifrost proxy. `__UPSTREAM__` is substituted by
# `make bifrost-up BIFROST_URL=http://<bifrost-host>:6385` before the ConfigMap is created.
# Injects a default X-OpenStack-Ironic-API-Version (Ironic 406s writes without one) and
# preserves any client-sent value. Forwards everything else upstream as-is.
events {}
http {
  map $http_x_openstack_ironic_api_version $ver {
    default $http_x_openstack_ironic_api_version;
    ''      '1.81';
  }
  server {
    listen 8080;
    location /healthz { return 200; }
    location / {
      proxy_pass __UPSTREAM__;
      proxy_set_header Host $http_host;
      proxy_set_header X-OpenStack-Ironic-API-Version $ver;
      proxy_read_timeout 120s;
    }
  }
}
