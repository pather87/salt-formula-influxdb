{%- from "influxdb/map.jinja" import server with context %}

{% if grains['os'] == 'Debian' %}
influxdb_repo:
  pkgrepo.managed:
    - humanname: influxdb
    - name: deb https://repos.influxdata.com/debian {{ grains['lsb_distrib_codename'] }} stable
    - file: /etc/apt/sources.list.d/influxdb.list
    - key_url: https://repos.influxdata.com/influxdb.key
{% endif %}

{%- if server.enabled %}


influxdb_packages:
  pkg.installed:
  - names: {{ server.pkgs }}
  - require:
    - pkgrepo: influxdb_repo

influxdb_config:
  file.managed:
  - name: /etc/influxdb/influxdb.conf
  - source: salt://influxdb/files/influxdb.conf
  - template: jinja
  - require:
    - pkg: influxdb_packages

influxdb_default:
  file.managed:
  - name: /etc/default/influxdb
  - source: salt://influxdb/files/default
  - template: jinja
  - require:
    - pkg: influxdb_packages

{%- if not grains.get('noservices', False) %}

influxdb_service:
  service.running:
  - enable: true
  - name: {{ server.service }}
  # This delay is needed before being able to send data to server to create
  # users and databases.
  - init_delay: 5
  - watch:
    - file: influxdb_config
    - file: influxdb_default

{%- endif %}

{% set url_for_query = "http://{}:{}/query".format(server.http.bind.address, server.http.bind.port) %}
{% set admin_created = false %}

{%- if server.admin.get('user', {}).get('enabled', False) %}
  {% set query_create_admin = "--data-urlencode \"q=CREATE USER {} WITH PASSWORD '{}' WITH ALL PRIVILEGES\"".format(server.admin.user.name, server.admin.user.password) %}
  {% set admin_url = "http://{}:{}/query?u={}&p={}".format(server.http.bind.address, server.http.bind.port, server.admin.user.name, server.admin.user.password) %}
influxdb_create_admin:
  cmd.run:
  - name: curl -f -S -POST "{{ url_for_query }}" {{ query_create_admin }} || curl -f -S -POST "{{ admin_url }}" {{ query_create_admin }}
  {%- if not grains.get('noservices', False) %}
  - require:
    - service: influxdb_service
  {%- endif %}
  {% set url_for_query = admin_url %}
  {% set admin_created = true %}
{%- endif %}

# An admin must exist before creating others users
{%- if admin_created %}
  {%- for user_name, user in server.get('user', {}).iteritems() %}
    {%- if user.get('enabled', False) %}
      {%- if user.get('admin', False) %}
        {% set query_create_user = "--data-urlencode \"q=CREATE USER {} WITH PASSWORD '{}' WITH ALL PRIVILEGES\"".format(user.name, user.password) %}
      {%- else %}
        {% set query_create_user = "--data-urlencode \"q=CREATE USER {} WITH PASSWORD '{}'\"".format(user.name, user.password) %}
      {%- endif %}
influxdb_create_user_{{user.name}}:
  cmd.run:
    - name: curl -f -S -POST "{{ url_for_query }}" {{ query_create_user }}
    - require:
      - cmd: influxdb_create_admin
    # TODO: manage user deletion
    {%- endif %}
  {%- endfor %}
{%- endif %}

{%- for db_name, db in server.get('database', {}).iteritems() %}
  {%- if db.get('enabled', False) %}
    {% set query_create_db = "--data-urlencode \"q=CREATE DATABASE {}\"".format(db.name) %}
influxdb_create_db_{{db.name}}:
  cmd.run:
    - name: curl -f -S -POST "{{ url_for_query }}" {{ query_create_db }}
    {%- if admin_created %}
    - require:
      - cmd: influxdb_create_admin
    {%- endif %}
  # TODO: manage database deletion

    {% for rp in db.get('retention_policy', []) %}
    {% set rp_name = rp.get('name', 'autogen') %}
    {% if rp.get('is_default') %}
      {% set is_default = 'DEFAULT' %}
    {% else %}
      {% set is_default = '' %}
    {% endif %}
    {% set duration = rp.get('duration', 'INF') %}
    {% set replication = rp.get('replication', '1') %}
    {% if rp.get('shard_duration') %}
      {% set shard_duration = 'SHARD DURATION {}'.format(rp.shard_duration) %}
    {% else %}
      {% set shard_duration = '' %}
    {% endif %}
    {% set query_retention_policy = 'RETENTION POLICY {} ON {} DURATION {} REPLICATION {} {} {}'.format(
        rp_name, db.name, duration, replication, shard_duration, is_default)
    %}
influxdb_retention_policy_{{db.name}}_{{ rp_name }}:
  cmd.run:

    - name: curl -s -S -POST "{{ url_for_query }}" --data-urlencode "q=CREATE {{ query_retention_policy }}"|grep -v "policy already exists" || curl -s -S -POST "{{ url_for_query }}" --data-urlencode "q=ALTER {{ query_retention_policy }}"
    - require:
      - cmd: influxdb_create_db_{{db.name}}
    {%- endfor %}
  {%- endif %}
{%- endfor %}

# An admin must exist to manage grants, otherwise there is no user.
{%- if admin_created %}
{%- for grant_name, grant in server.get('grant', {}).iteritems() %}
  {%- if grant.get('enabled', False) %}
    {% set query_grant_user_access = "--data-urlencode \"q=GRANT {} ON {} TO {}\"".format(grant.privilege, grant.database, grant.user) %}
influxdb_grant_{{grant_name}}:
  cmd.run:
    - name: curl -f -S -POST "{{ url_for_query }}" {{ query_grant_user_access }}
    - require:
      - cmd: influxdb_create_db_{{grant.database}}
      - cmd: influxdb_create_user_{{grant.user}}
      - cmd: influxdb_create_admin
    # TODO: manage grant deletion (if needed)
  {%- endif %}
{%- endfor %}
{%- endif %}

{%- endif %}
