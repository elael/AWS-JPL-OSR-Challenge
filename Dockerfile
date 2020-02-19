################################################################################
# base system
################################################################################

FROM tensorflow/tensorflow:latest-gpu as system



RUN sed -i 's#http://archive.ubuntu.com/ubuntu/#mirror://mirrors.ubuntu.com/mirrors.txt#' /etc/apt/sources.list; 


# built-in packages
ENV DEBIAN_FRONTEND noninteractive
RUN apt update \
    && apt install -y --no-install-recommends software-properties-common curl apache2-utils \
    && apt update \
    && apt install -y --no-install-recommends --allow-unauthenticated \
        supervisor nginx sudo net-tools zenity xz-utils \
        dbus-x11 x11-utils alsa-utils \
        mesa-utils libgl1-mesa-dri \
    && apt autoclean -y \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*
# install debs error if combine together
RUN add-apt-repository -y ppa:fcwu-tw/apps \
    && apt update \
    && apt install -y --no-install-recommends --allow-unauthenticated \
        xvfb x11vnc=0.9.16-1 \
        vim-tiny firefox chromium-browser ttf-ubuntu-font-family ttf-wqy-zenhei  \
    && add-apt-repository -r ppa:fcwu-tw/apps \
    && apt autoclean -y \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN apt update \
    && apt install -y --no-install-recommends --allow-unauthenticated \
        lxde gtk2-engines-murrine gnome-themes-standard gtk2-engines-pixbuf gtk2-engines-murrine arc-theme \
    && apt autoclean -y \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*
 
 
# Additional packages require ~600MB
# libreoffice  pinta language-pack-zh-hant language-pack-gnome-zh-hant firefox-locale-zh-hant libreoffice-l10n-zh-tw

# tini to fix subreap
ARG TINI_VERSION=v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /bin/tini
RUN chmod +x /bin/tini

# ffmpeg
RUN apt update \
    && apt install -y --no-install-recommends --allow-unauthenticated \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /usr/local/ffmpeg \
    && ln -s /usr/bin/ffmpeg /usr/local/ffmpeg/ffmpeg

# python library
COPY rootfs/usr/local/lib/web/backend/requirements.txt /tmp/
RUN apt-get update \
    && dpkg-query -W -f='${Package}\n' > /tmp/a.txt \
    && apt-get install -y python-pip python-dev build-essential \
	&& pip install setuptools wheel && pip install -r /tmp/requirements.txt \
    && dpkg-query -W -f='${Package}\n' > /tmp/b.txt \
    && apt-get remove -y `diff --changed-group-format='%>' --unchanged-group-format='' /tmp/a.txt /tmp/b.txt | xargs` \
    && apt-get autoclean -y \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/cache/apt/* /tmp/a.txt /tmp/b.txt


################################################################################
# builder
################################################################################
FROM tensorflow/tensorflow:latest-gpu as builder


RUN sed -i 's#http://archive.ubuntu.com/ubuntu/#mirror://mirrors.ubuntu.com/mirrors.txt#' /etc/apt/sources.list; 


RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg patch

# nodejs
RUN curl -sL https://deb.nodesource.com/setup_8.x | bash - \
    && apt-get install -y nodejs

# yarn
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y yarn

# build frontend
COPY web /src/web
RUN cd /src/web \
    && yarn \
    && yarn build



################################################################################
# merge
################################################################################
FROM system
LABEL author="Joe Barbere"

COPY --from=builder /src/web/dist/ /usr/local/lib/web/frontend/
COPY rootfs /
RUN ln -sf /usr/local/lib/web/frontend/static/websockify /usr/local/lib/web/frontend/static/novnc/utils/websockify && \
	chmod +x /usr/local/lib/web/frontend/static/websockify/run

EXPOSE 80
WORKDIR /root
ENV HOME=/home/ubuntu \
    SHELL=/bin/bash
HEALTHCHECK --interval=30s --timeout=5s CMD curl --fail http://127.0.0.1:6079/api/health
ENTRYPOINT ["/startup.sh"]

RUN apt update && apt install -y \
	dirmngr \
	wget \
	tzdata \
	&& rm -rf /var/lib/apt/lists/*

# adding keys for ROS
RUN sh -c 'echo "deb http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" > /etc/apt/sources.list.d/ros-latest.list'
RUN apt-key adv --keyserver 'hkp://keyserver.ubuntu.com:80' --recv-key C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654
RUN wget http://packages.osrfoundation.org/gazebo.key -O - | apt-key add -

# installing ros
RUN apt update && apt install -y \
	python-rosinstall \
	python3-colcon-common-extensions \
	python3-pip \
	ros-melodic-desktop-full \
	ros-melodic-effort-controllers \
	#ros-melodic-ros-controllers \
	#ros-melodic-ros-control \
	#ros-melodic-teleop-twist-keyboard \
	&& rm -rf /var/lib/apt/lists/*

# installing additional stuff
RUN apt update && apt install -y \
	curl \
	mlocate \
	tmux \
	htop \
	git \
	nano \
	&& rm -rf /var/lib/apt/lists/*

# update ROS dependencies
RUN rosdep init && rosdep update

# installing colcon bundle tools
RUN pip3 install -U setuptools && pip3 install colcon-ros-bundle

# match robomaker dir structure
RUN mkdir -p /home/ubuntu/catkin_ws/src

# create central dir for mapping data back to the host
RUN mkdir /data

# install minio
RUN wget https://dl.min.io/server/minio/release/linux-amd64/minio
RUN sudo chmod +x minio
RUN sudo mv minio /usr/local/bin
RUN sudo useradd -r minio-user -s /sbin/nologin
RUN sudo chown minio-user:minio-user /usr/local/bin/minio

# install ELK
RUN wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
RUN echo "deb https://artifacts.elastic.co/packages/6.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-6.x.list
RUN sudo apt-get update
RUN sudo apt-get install -y default-jdk
RUN sudo apt-get install -y elasticsearch logstash kibana && rm -rf /var/lib/apt/lists/*

# install additional useful python packages
RUN pip3 install elasticsearch python-logstash jupyter tornado && pip3 install jupyter-tensorboard

# install cuda/cudnn
COPY cuda_9.0.176_384.81_linux.run /tmp
COPY cudnn-9.0-linux-x64-v7.6.5.32.tgz /tmp

WORKDIR /tmp

RUN chmod +x cuda_9.0.176_384.81_linux.run
RUN ./cuda_9.0.176_384.81_linux.run --silent --toolkit --override

RUN touch ~/.bashrc
RUN echo 'export PATH=/usr/local/cuda-9.0/bin:$PATH' >> ~/.bashrc \
  && echo 'export LD_LIBRARY_PATH=/usr/local/cuda-9.0/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc \
  && echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc \
  && . ~/.bashrc

RUN tar -xzvf cudnn-9.0-linux-x64-v7.6.5.32.tgz

RUN cp -P cuda/include/cudnn.h /usr/local/cuda-9.0/include
RUN cp -P cuda/lib64/libcudnn* /usr/local/cuda-9.0/lib64/
RUN chmod a+r /usr/local/cuda-9.0/lib64/libcudnn*