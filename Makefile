all:

白姑大山:
	ruby generate.rb 白姑大山/milestone.yaml
	ruby generate.rb 白姑大山/blank.yaml
.PHONY: 白姑大山

能高安東軍:
	ruby generate.rb 能高安東軍/milestone.yaml
	ruby generate.rb 能高安東軍/milestone2.yaml
	ruby generate.rb 能高安東軍/blank.yaml
	ruby generate.rb 能高安東軍/blank2.yaml
#	ruby generate.rb 能高安東軍/hazard.yaml
#	ruby generate.rb 能高安東軍/water.yaml
.PHONY: 能高安東軍