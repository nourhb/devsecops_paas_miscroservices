{{/*
Static SPA (vite/angular) images use nginx on port 8080 as non-root UID 101.
*/}}
{{- define "simple-app.staticNginx" -}}
{{- or .Values.staticNginx (eq (int (.Values.service.targetPort | default 3000)) 8080) -}}
{{- end -}}

{{- define "simple-app.nginxVolumes" -}}
- name: paas-nginx-conf
  configMap:
    name: paas-nginx-override
- name: paas-nginx-cache
  emptyDir: {}
- name: paas-nginx-run
  emptyDir: {}
- name: paas-nginx-log
  emptyDir: {}
- name: paas-nginx-tmp
  emptyDir: {}
{{- end -}}

{{- define "simple-app.nginxVolumeMounts" -}}
- name: paas-nginx-conf
  mountPath: /etc/nginx/conf.d/default.conf
  subPath: default.conf
- name: paas-nginx-cache
  mountPath: /var/cache/nginx
- name: paas-nginx-run
  mountPath: /var/run
- name: paas-nginx-log
  mountPath: /var/log/nginx
- name: paas-nginx-tmp
  mountPath: /tmp
{{- end -}}
