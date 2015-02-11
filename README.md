shairport_plugin for Mac OS X
=============================

ShairPort Plugin for Squeezebox Server adds airTunes support for each Squeezebox server client.

To install the plugin first [install Homebrew](http://brew.sh/#install), then install the dependencies as follows:

	export ARCHFLAGS="-arch x86_64"
	brew install pkg-config libao
	# while perl is already installed with OS X, 
	# this updates to the latest version and makes sure dependencies are in order
	curl -L http://xrl.us/installperlosx | bash
	sudo perl -MCPAN -e 'install Crypt::OpenSSL::RSA; install IO::Socket::INET6; install Net::SDP'

Now open the LMS GUI; click on Settings, then select the Plugins tab, at the bottom of the page add the repo:

http://raw.github.com/adamcohenrose/shairport_plugin/master/public.xml

Next install the plugin and enable as per usual.

See http://forums.slimdevices.com/showthread.php?100379-Announce-ShairTunes-Plugin

Thanks to [John Slack](http://jslack.blogspot.co.uk/2014/08/airplay.html) for further exploration on OS X
