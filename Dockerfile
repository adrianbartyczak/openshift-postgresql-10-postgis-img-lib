# 
# File:
#   Dockerfile
# 
# Description:
#   The Dockerfile for image adrianbartyczak/openshift-postgresql-10-postgis
# 

FROM openshift/base-centos7

# ============================================
#   Set up the system
# ============================================

# Enable the EPEL repository as it is needed by the dependecies of PostGIS.
RUN yum -y install epel-release

# Import the EPEL GPG-key to ensure that package integrity has not been
# compromised.
RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

# As the system of base CentOS7 images is not updated, the system must be
# updated. (Uncomment this if needed, however, it will make the uncompressed
# image about 750Mb larger.)
# RUN yum -y update

# ============================================
#   Install PostgreSQL and PostGIS
# ============================================

RUN pgdgRpmUrl='https://yum.postgresql.org/10/redhat/rhel-7-x86_64/' && \
      pgdgRpmUrl+='pgdg-centos10-10-2.noarch.rpm' && \
      rpm -Uvh "${pgdgRpmUrl}" && \
      yum -y install postgresql10 postgresql10-server postgis23_10

# Clean all yum cache files to make the image smaller.
RUN yum clean all

# ============================================
#   Set up the the base components of the image
# ============================================

# Important: This section is placed after setting up the system and installing
#            PostgreSQL and PostGIS so that changes to the image setup do not
#            cause the layers in the first section to be re-created.

# Create environment variables to inform about software versions being used
# inside the builder.
ENV POSTGRESQL_VERSION=10.4
ENV POSTGIS_VERSION=2.3

# Set labels used in OpenShift to describe the builder images.
LABEL io.k8s.description="An object-relational database management system \
with support for geographic objects" \
      io.k8s.display-name="PostgreSQL 10 extended with PostGIS" \
      # Uncomment this if the service for the application that will run this
      # image will be exposed.
      # io.openshift.expose-services="8080:http" \
      io.openshift.tags="builder,sql,postgresql,postgis"

# ============================================
#   Set up the components of the image needed to run it on OpenShift Origin
# ============================================

# Note on building to run on OpenShift Origin:
#   In order to sccessfully run the image built by this Dockerfile on OpenShift
#   Origin, the ID of the user OpenShift Origin will runs the image as must be
#   assigned to argument variable OPENSHIFT_ORIGIN_USER_ID.
# 
#   To get this ID, a new OpenShift application must be created with the image
#   must be built by this packaging library using any OpenShift Origin using ID
#   and a S2I source repository containing a run script that prints the output
#   of the user it ran as (this can be done with command `id -u`). Then, the
#   logs of the pod that ran the application must be checked. (The complete
#   command to do this can be found at
#   https://hub.docker.com/r/adrianbartyczak/openshift-postgresql-10-postgis/.)
# 
#   The image built by this Dockerfile must then be rebuilt with the ID assigned
#   to argument variable OPENSHIFT_ORIGIN_USER_ID. (This can be done via option
#   `--build-arg OPENSHIFT_ORIGIN_USER_ID=<id>`.)
# 
#   Note that the user OpenShift Origin runs images as is the same across a
#   project.

ARG OPENSHIFT_ORIGIN_USER_ID=1027270000

# Note on the default user created by the base centos7 image:
#   The base-centos7 image creates a default user with name "default" and ID
#   1001 but it cannot be used in the container of the image built by this
#   Dockerfile in OpenShift Origin. The entry for this user in /etc/passwd is
#   the following:
#       default:x:1001:0:Default Application User:/opt/app-root/src:/sbin/nologin

# Make user OPENSHIFT_ORIGIN_USER_ID own /opt/app-root.
RUN chown -R $OPENSHIFT_ORIGIN_USER_ID:$OPENSHIFT_ORIGIN_USER_ID /opt/app-root

# ============================================
#   Set up PostgreSQL
# ============================================

# Manually create directory /var/lib/postgres and make it be owned by a user
# other than root. This is for the reason that the initdb executable must be
# executed by a user other than root.
RUN mkdir -p /var/lib/postgres && chown 1001:1001 /var/lib/postgres

# The user that owns the server process must have write permissions on
# /var/run/postgresql so the server can create a UNIX socket file for binding
# the address it will listen on.
RUN chown -R 1001:1001 /var/run/postgresql

# Switch to user 1001 because the initdb executable must be run "as the user
# that will own the server process, because the server needs to have access
# to the files and directories that initdb creates" (PostgreSQL documentation)
# and because the PostgreSQL server will be started to set up databases for the
# image to run on OpenShift Origin, once again requiring the process to be owned
# by the user that owns the data directory.
USER 1001

# Initialize PostgreSQL. Note: This cannot be done in an OpenShift S2I assembly
# script (unless the user it is run as has root access) because PostgreSQL
# databases must be set up for the image in the image build because only the
# image build has permission to change ownerships on files and directories that
# will be accessed by the PostgreSQL server and the initdb executable must of
# course be executed before then.
# Note: initdb creates a PostgreSQL role with the name of the system user it was
# executed as (in this case "default").
RUN /usr/pgsql-10/bin/initdb --locale en_US.UTF-8 -E UTF8 -D \
      /var/lib/postgres/data

# Temporarily start the PostgreSQL server and create (1) a database used as a
# template for creating PostGIS enabled databases and (2) the default database
# that will be connected to by the default PostgreSQL role.
RUN /usr/pgsql-10/bin/pg_ctl -D /var/lib/postgres/data -w start && \
      createdb template_postgis -E UTF-8 && \
      psql -d template_postgis -c 'CREATE EXTENSION postgis' && \
      psql -d template_postgis -c 'CREATE EXTENSION pgcrypto' && \
      psql -d template_postgis -c 'CREATE EXTENSION "uuid-ossp"' && \
      \
      # Manually create database "default". The reason for this is based on the
      # fact that OpenShift Origin runs an image as a user created by it. When
      # the psql executable is executed, it uses the name of the system user as
      # the name of the PostgreSQL role to connect as. If a role with this name
      # does not exist, PostgreSQL will show error "FATAL:  role
      # "<system_user_name>" does not exist". Furthermore, if in the uncommon
      # case the user executing the psql executable does not exist in the
      # operating system, PostgreSQL will show error "local user with ID
      # <id_of_system_user> does not exist". The user OpenShift Origin runs the
      # image as of course does not exist in the system and therefore has no
      # name. As a result, this Dockerfile instructs the image build invoked
      # with it to create a "psql" wrapper script (at the bottom of the next
      # section) that always connects as role "default". As the default role
      # used to connect as is "default" and psql uses the name of the role used
      # to connect as-as the name of the default database to connect to,
      # database "default" is created. (Note: Database "default" is created with
      # the PostGIS template database to illustrate the use of the PostGIS
      # template database).
      createdb default --owner=default --template='template_postgis' && \
      \
      # Create role/user "postgres" as it is should exist and is often used when
      # setting up databases and other components of PostgreSQL.
      createuser postgres --superuser && \
      \
      /usr/pgsql-10/bin/pg_ctl -D /var/lib/postgres/data stop

# Copy the necessary configuration files for running the PostgreSQL server
# inside a Kubernetes container.
COPY ./configurations/* /var/lib/postgres/data/

# ============================================
#   Set up the PostgreSQL-related components of the image required to run the
#   PostgreSQL server in the container of the image run on OpenShift Origin
# ============================================

USER root

# The user that runs the PostgreSQL server must be the owner of the data
# directory to access files in it.
RUN chown -R $OPENSHIFT_ORIGIN_USER_ID:$OPENSHIFT_ORIGIN_USER_ID \
      /var/lib/postgres/data

# The ownership of /var/run/postgresql must be change for the user OpenShift
# Origin will run the image built by this Dockerfile as for the same reason
# it was changed for the "default" user in the previous section.
RUN chown $OPENSHIFT_ORIGIN_USER_ID:$OPENSHIFT_ORIGIN_USER_ID \
      /var/run/postgresql

# For some reason, the base centos7 images includes binary /usr/bin/psql,
# however, the installed PostgreSQL includes file /usr/pgsql-10/bin/psql.
# Running "psql" runs /usr/bin/psql which does not use the same version as the 
# installed PostgreSQL package, resulting in a warning message. Therefore, it
# and other PostgreSQL binaries must be be overwritten to use the binaries in
# /usr/pgsql-10/bin/.
RUN ln -sf /usr/pgsql-10/bin/psql /usr/bin/psql && \
    ln -sf /usr/pgsql-10/bin/pg_dump /usr/bin/pg_dump && \
    ln -sf /usr/pgsql-10/bin/pg_restore /usr/bin/pg_restore

# Add the user OpenShift Origin will run the image built by this Dockerfile to
# the system. This is required because PostgreSQL executables, such as psql and
# createdb, use the name of the system user that executed one as the name of the
# role to connect to the server with. As the user OpenShift Origin runs the
# image built by this Dockerfile does not exist in the system, PostgreSQL prints
# error "local user with ID <OPENSHIFT_ORIGIN_USER_ID> does not exist."
RUN userdel default && \
      groupadd default && \
      adduser default -u $OPENSHIFT_ORIGIN_USER_ID -g default --no-log-init

# Note: To minimize layers, adding the user OpenShift Origin will run the image
#       built by this Dockerfile to the system (done in the last instruction of
#       this section) can be done before manually creating and changing the
#       ownership of directory /var/lib/postgres (done in the first instruction
#       of the previous section). This would remove the first two RUN
#       instructions of this section and has the advantage of allowing
#       PostgreSQL to be initialized in an S2I run script. Since the image built
#       by this Dockerfile has to be rebuilt anyways to be set up to run as the
#       user OpenShift Origin will run the image as and for referencing reasons,
#       this is not done.

# ============================================
#   Set up the remaining components of the image
# ============================================

# Set the default user for the image. This is only for running the image built
# by this Dockerfile as a plain Docker container and not with an OpenShift
# application as the user OpenShift Origin run images is a user created by the
# pod that runs the application. Note: To maintain run consistency between
# Docker and OpenShift Origin, this Dockerfile instructs the image to run as a
# user with ID assigned to argument variable OPENSHIFT_ORIGIN_USER_ID.
USER $OPENSHIFT_ORIGIN_USER_ID

# Expose port 5432 so the PostgreSQL server can be connected through it from
# outside the OpenShift pod of the container running it.
EXPOSE 5432

# Add OpenShift S2I source files to the image built by this Dockerfile so an S2I
# image built from it can be run without a separate S2I source repository. Note:
# Creating an S2I image with the image built by this Dockerfile and an S2I
# source repository will cause the S2I source repository to override the S2I
# source files in the S2I image built from the image built by this Dockerfile.
# Note: Directory /usr/libexec/s2i is the location defined for S2I source files
# in the OpenShift base CentOS7 images as label io.openshift.s2i.scripts-url.
COPY ./.s2i/bin/ /usr/libexec/s2i

# Execute the script to run when the image built by this Dockerfile is run.
CMD ["/usr/libexec/s2i/run"]

