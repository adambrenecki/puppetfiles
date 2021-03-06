# Exposes a Nginx upstream at http://{name}.
#
# Parameters:
#  name: name of the app
#  repo: URL to the Git repository where the app is stored
#  branch: Branch of that repo to check out
#  key: path to SSH private key to use (can be a puppet:// path)
#  user: system user to run the app under
#  dbname: name of the db to connect the app to
#  dbpass: db password
#  project_name: name of the Django project
#  manage_in_project: true if manage.py is inside the project
#  secret_key: The value to use for Django's secret key
#  extra_config: Extra stuff to add to the config file.
#
# Expects the app to have:
#  A requirements file at /requirements.txt
#  A manage.py either /manage.py or /{project_name}/manage.py
#  A settings.py that imports /{project_name}/local_settings.py at the end
define abre::django::project (
  $repo,
  $branch = 'master',
  $key = undef,
  $user = $title,
  $dbname = $title,
  $dbpass,
  $project_name,
  $manage_in_project = false,
  $secret_key,
  $extra_config,
){
  if ($manage_in_project) {
    $managepy = "${project_name}/manage.py"
  } else {
    $managepy = "manage.py"
  }

  # Database
  postgresql::server::db {$dbname:
    user => $dbname,
    password => $dbpass,
  }

  # User
  user {$user:
    ensure => present,
    home => "/home/${user}",
    managehome => true,
  }

  # Source Code
  file {"/home/${user}/id":
    ensure => present,
    source => $key,
    require => User[$user],
    owner => $user,
    group => $user,
    mode => 0600,
  }

  vcsrepo {"/home/${user}/app":
    ensure => latest,
    owner => $user,
    group => $user,
    provider => git,
    require => User[$user],
    source => $repo,
    revision => $branch,
    identity => "/home/${user}/id",
    notify => Upstart::Job[$title],
  }

  # Virtualenv
  virtualenv::env {"/home/${user}/virtualenv":
    user => $user,
    group => $user,
    require => User[$user],
  }

  virtualenv::package {"${user}-gunicorn":
    package => 'gunicorn',
    env => "/home/${user}/virtualenv",
  }

  virtualenv::package {"${user}-psycopg2":
    package => 'psycopg2',
    env => "/home/${user}/virtualenv",
    require => [
      Package['libpq-dev'],
      Package['python-dev'],
    ],
  }

  virtualenv::requirements {"/home/${user}/app/requirements.txt":
    env => "/home/${user}/virtualenv",
    require => Vcsrepo["/home/${user}/app"],
  }

  # Settings file
  file {"/home/${user}/app/${project_name}/local_settings.py":
    ensure => file,
    owner => 'site',
    group => 'site',
    require => Vcsrepo['/home/site/app'],
    notify => Upstart::Job['site'],
    content => template('abre/django/local_settings.py.erb'),
  }

  # App setup
  exec {"${user}-syncdb":
    command => "/home/${user}/virtualenv/bin/python ${managepy} syncdb --migrate --noinput",
    user => $user,
    group => $user,
    cwd => "/home/${user}/app",
    require => [
      Virtualenv::Requirements["/home/${user}/app/requirements.txt"],
      Virtualenv::Package["${user}-psycopg2"],
    ],
  }

  exec {"${user}-collectstatic":
    command => "/home/${user}/virtualenv/bin/python ${managepy} collectstatic --noinput",
    user => $user,
    group => $user,
    cwd => "/home/${user}/app",
    require => [
      Virtualenv::Requirements["/home/${user}/app/requirements.txt"],
      Virtualenv::Package["${user}-psycopg2"],
    ],
  }

  # Application
  nginx::resource::upstream {$title:
    ensure => present,
    members => "unix:/home/${user}/http.sock",
  }
  upstart::job {$title:
    ensure => present,
    respawn => true,
    exec => "/home/${user}/virtualenv/bin/gunicorn wsgi:application -b unix:/home/${user}/http.sock",
    user => $user,
    group => $user,
    chdir => "/home/${user}/app",
    require => [
      Vcsrepo["/home/${user}/app"],
      Virtualenv::Package["${user}-gunicorn"],
      File["/home/${user}/app/${project_name}/local_settings.py"],
      Exec["${user}-syncdb"],
    ],
    environment => {
      'PATH' =>
      '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games',
    },
  }
}
