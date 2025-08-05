all: spec

spec: index.bs
	curl https://api.csswg.org/bikeshed/ -F file=@index.bs -F force=1 > index.html

warn:
	curl https://api.csswg.org/bikeshed/ -F file=@index.bs -F output=err -F die-on=everything

