### DEPRECATED ###
package Web::Dashboard;
use Moose;
extends 'Web';
use Data::Dumper;
use Plack::Request;
use Plack::Session;
use Encode;
use Module::Pluggable require => 1, search_path => [qw(Dashboard)];
use JSON;
use Plack::Middleware::Auth::Basic;
use Date::Manip;

sub call {
	my ($self, $env) = @_;
    $self->session(Plack::Session->new($env));
	my $req = Plack::Request->new($env);
	my $res = $req->new_response(200); # new Plack::Response
	$res->content_type('text/html');
	$res->header('Access-Control-Allow-Origin' => '*');
	$self->path_to_inc('../');
	
	my $dashboard_name = $self->_extract_method($req->request_uri);
	$self->api->log->debug('method: ' . $dashboard_name);
	
	unless ($self->api->conf->get('dashboards/' . $dashboard_name)){
		$res->status(404);
		$res->body('not found');
		return $res->finalize();
	}
	my $user = $self->api->get_user($req->user);
	if ($user){
		$self->session->set('user', $user->freeze);
		$self->session->set('user_info', $user->TO_JSON);
	}
	else {
		$res->status(401);
		die('Unauthorized');
	}
	
	my $args = $req->parameters->as_hashref;
	my $time_units = {
		seconds => { groupby => 'timestamp', multiplier => 1 },
		minutes => { groupby => 'minute', multiplier => 60 },
		hours => { groupby => 'hour', multiplier => 3600 },
		days => { groupby => 'day', multiplier => 86400 },
		months => { groupby => 'month', multiplier => 2592000 },
		years => { groupby => 'year', multiplier => 946080000 },
	};
	
	foreach my $arg (keys %$args){
		if (exists $time_units->{ $arg }){
			$args->{groupby} = $time_units->{ $arg }->{groupby};
			$args->{start_time} = (time() - ($time_units->{ $arg }->{multiplier} * int($args->{$arg})));
			$self->api->log->trace('set start_time to ' . (scalar localtime($args->{start_time})));
			last;
		}
	}
	
	if (exists $args->{start}){
		$args->{start_time} = UnixDate(ParseDate(delete $args->{start}), '%s');
		$self->api->log->trace('set start_time to ' . (scalar localtime($args->{start_time})));
	}
	if (exists $args->{end}){
		$args->{end_time} = UnixDate(ParseDate(delete $args->{end}), '%s');
		$self->api->log->trace('set end_time to ' . (scalar localtime($args->{end_time})));
	}
	else {
		$args->{end_time} = time;
	}
	
	my ($query, $sth);
	$query = 'SELECT * FROM v_dashboards WHERE uid=? AND alias=? ORDER BY x,y';
	$sth = $self->api->db->prepare($query);
	$sth->execute($self->api->user->uid, $dashboard_name);
	my %dashboards;
	my @queries;
	while (my $row = $sth->fetchrow_hashref){
		$dashboards{ $row->{dashboard_id} } ||= [];
		$dashboards{ $row->{dashboard_id} }->[ $row->{y} ] ||= { title => $row->{dashboard_title}, charts => [] };
		$dashboards{ $row->{dashboard_id} }->[ $row->{y} ]->{charts} ||= { title => $row->{chart_title}, type => $row->{chart_type}, queries => [] };
		$dashboards{ $row->{dashboard_id} }->[ $row->{y} ]->{charts}->{queries}->[ $row->{x} ] = { query => $row->{query}, label => $row->{label} }; 
	}
	
	foreach my $dashboard_id (sort { $a cmp $b } keys %dashboards){
		foreach my $chart (@{ $dashboards{$dashboard_id} }){
			foreach my $query (@{ $chart->{queries} }){
				my $query_meta_params = {
					start => $self->start_time,
					end => $self->end_time,
					comment => $query->{label},
					type => $chart->{type},
				};
				$query_meta_params->{groupby} = [$self->groupby] unless $query->{query} =~ /\sgroupby[:=]/ or $query->{query} =~ /sum\([^\)]+\)$/;
				$query->{query_string} = delete $query->{query};
				$query->{query_meta_params} = $query_meta_params;
				$query->{user} = $self->user;
			}
		}
		push @queries, $dashboards{$dashboard_id};
	}
	$self->api->log->debug('queries: ' . Dumper(\@queries));

	if ($@){
		my $e = $@;
		$self->api->log->error($e);
		$res->body([encode_utf8($self->api->json->encode({error => $e}))]);
	}
	else {
		#$self->api->log->debug('data: ' . Dumper($dashboard->data));
		#$res->body([$self->index($req, $dashboard->data)]);
		$self->api->log->debug('data: ' . Dumper(\@queries));
		$res->body([$self->index($req, \@queries)]);
	}
	$res->finalize();
}

sub index {
	my $self = shift;
	my $req = shift;
	my $data = shift;
	return $self->_get_headers() . $self->_get_index_body($data);
}

sub _get_index_body {
	my $self = shift;
	my $data = shift;
	#TODO sort data
	my $HTML = '<script>YAHOO.ELSA.queryResults = ' . encode_json($data) . "; YAHOO.ELSA.includeDir = '../inc';</script>\n";
	$HTML .= <<'EOHTML'
<script>YAHOO.util.Event.addListener(window, "load", function(){
	YAHOO.ELSA.initLogger();
	var iAlarm = 20000;
	var sBgcolor = false;
	
	for (var i in YAHOO.ELSA.queryResults){
		var sDescription = YAHOO.ELSA.queryResults[i][0];
		var sGroupby = YAHOO.ELSA.queryResults[i][2];
		var oResults = YAHOO.ELSA.queryResults[i][1].results[sGroupby];
		// create data formatted for chart
		var aX = [];
		var aY = [];
		for (var j in oResults){
			var oRec = oResults[j];
			if (oRec['@groupby'] > iAlarm){
				sBgcolor = '#FF0000';
			}
			aX.push(oRec['@groupby']);
			aY.push(oRec['@count']);
		}
		var oChartData = {
			x: aX
		};
		oChartData[sGroupby] = aY;
		logger.log('oChartData', oChartData);
		var oEl = document.createElement('div');
		oEl.id = 'chart_id_' + i;
		YAHOO.util.Dom.get('panel_root').appendChild(oEl);
		var oChart = new YAHOO.ELSA.Chart.Auto({
			container:oEl.id, 
			type:'bar', 
			title:sDescription, 
			data:oChartData, 
			callback:function(){logger.log('null action');}, 
			width:1000, 
			height:300, 
			bgColor:sBgcolor,
			includeDir: YAHOO.ELSA.includeDir
		});
	}
});</script>
</head>
<body class=" yui-skin-sam">
<div id="panel_root"></div>
</body>
</html>
EOHTML
;

	return $HTML;
}

1;