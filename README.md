MYSQL-M3
======================

### 소개
- mysql-m3는 [mysql-mmm](http://mysql-mmm.org)의 fork product 입니다.
- mysql-mmm은 mysql replication 구조하에서 mysql 장애 발생시 vip 절체 및 replication 구조 변경을 자동화합니다.
- mysql-mmm 프로젝트는 2009년 이후 업데이트되고 있지 않으며, mysql-m3는 mysql-mmm의 기능 개선, 버그 패치 등을 포함하고 있습니다.

### 요구사항
- Redhat 계열 Linux (RHEL, CentOS, Oracle Linux)
- Perl 5.10, 5.16, 5.26 (Redhat 계열 Linux 6 ~ 8의 기본 Perl 버전, 버전이 다른 경우 하단 설명 참조)
- 모니터 전용 서버 (권장) 
- GTID Replication (권장)

### 설치
#### 1) 모니터 설치
```
$ make install_monitor PREFIX=/path/you/want
```
- PREFIX 지정하지 않는 경우 /usr/local/mysql-mmm 경로로 설치됩니다.
- 여러 개의 클러스터를 관리하는 경우 모니터는 최초 1회만 설치합니다.

#### 2) 에이전트 설치 (mysql 서버)
```
$ make install_agent PREFIX=/path/you/want
```
- PREFIX 지정하지 않는 경우 /usr/local/mysql-mmm 경로로 설치됩니다.

#### 3) MMM 접속 DB 계정 생성
- 모니터 서버와 각 에이전트(mysql 서버)의 IP로 모두 접속이 가능해야 합니다. 
- MySQL 5.7 이하
```
CREATE USER {MMM_USER}@{접속IP} IDENTIFIED BY 'xxxx';
GRANT PROCESS, SUPER, REPLICATION CLIENT ON *.* TO {MMM_USER}@{접속IP};
```
- MySQL 8.0 이상 
```
CREATE USER {MMM_USER}@{접속IP} IDENTIFIED WITH mysql_native_password BY 'xxxx';
GRANT PROCESS, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO {MMM_USER}@{접속IP};
GRANT CONNECTION_ADMIN, REPLICATION_SLAVE_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO {MMM_USER}@{접속IP};
```

#### 4) 모니터 설정 (추가)
- 설치경로/conf/mmm_mon_{Cluster}.conf 파일을 생성합니다. (mmm_mon_example.conf 참고)
- Cluster 값은 모니터 데몬의 port로 사용되므로, port range를 고려해서 결정해야 합니다.
- exclusive 속성의 role(writer) 1개는 필수, balanced 속성의 role (reader)는 옵션입니다. 
- VIP는 실제 mysql 서버의 IP와 동일 subnet의 IP를 사용합니다.
- multi source replication을 사용하는 DB 노드는 모니터링 대상 channel 명을 지정해야 합니다.

#### 5) 에이전트 설정
- 설치경로/conf/mmm_agent.conf 파일을 생성합니다. (mmm_agent_example.conf 참고)
- multi source replication을 사용하는 DB 노드는 Failover 대상 channel 명을 지정해야 합니다.

### DB 복제 구성
- Writer role을 가질 2대의 DB간 양방향 복제 구성 필요합니다.
- 그 외 DB는 최초 writer role을 할당받을 DB의 slave로 구성합니다.

### 구성 예시
#### 1) Single Master + N Slave
:warning: Master 노드와 예비 Master 노드간 양방향 복제를 구성하지만, 항상 Write는 한쪽 노드에서만 발생합니다.
```
# Example
db1 (192.168.56.101/writer + 192.168.56.105/reader) <──> db2 (192.168.56.102/reader)
 │
 ┣─> db3 (192.168.56.103/reader)
 │
 └─> db4 (192.168.56.104/reader)

# Config
<role writer>
  hosts db1, db2
  ips   192.168.56.101
  mode  exclusive
</role>

<role reader>
  hosts db1, db2, db3, db4
  ips   192.168.56.102, 192.168.56.103, 192.168.56.104, 192.168.56.105 
  mode  balanced
</role>
```

### 2) Dual Active Master + N Slave
:warning: Dual Active Master 환경에 Slave 노드가 존재하는 경우 GTID 복제 환경은 필수입니다.

:warning: Writer VIP 별로 접근하는 데이터가 구분되어야 합니다. (예: writer #1 : schema_A 사용, writer #2 : schema_B 사용)

```
# Example
db1 (192.168.56.101/writer) <──> db2 (192.168.56.102/writer)
 │
 └─> db3 (192.168.56.103/reader)

# Config
<role writer>
  hosts db1, db2
  ips   192.168.56.101, 192.168.56.102
  mode  balanced
</role>

<role reader>
  hosts db1, db2, db3
  ips   192.168.56.103
  mode  balanced
</role>
```

### 데몬 구동
#### 1) 모니터 데몬 구동
```
$ /etc/init.d/mysql-mmm-monitor start {Cluster}
or
$ systemctl start mysql-mmm-monitor@{Cluster}.service
```

#### 2) 에이전트 데몬 구동
```
$ /etc/init.d/mysql-mmm-agent start
or
$ systemctl start mysql-mmm-agent.service
```

### 클러스터 관리
```
$ mmm_control @{Cluster} command
Valid commands are:
    help                              - show this message
    ping                              - ping monitor
    show [more]                       - show status
    checks [<host>|all [<check>|all]] - show checks status
    set_online <host>                 - set host <host> online
    set_offline <host>                - set host <host> offline
    mode                              - print current mode.
    set_active                        - switch into active mode.
    set_manual                        - switch into manual mode.
    set_passive                       - switch into passive mode.
    move_role [--force] <role> <host> - move exclusive role <role> to host <host>
                                        (Only use --force if you know what you are doing!)
    set_ip <ip> <host>                - set role with ip <ip> to host <host>
```

### 기타
#### 1) MMM Tools
- mysql-m3에서는 mysql-mmm이 제공하던 mmm tools의 동작(LVM Snapshot 등)을 보장하지 않습니다.
  
#### 2) Perl 버전이 다른 경우
- 아래 Perl 모듈을 별도 설치 합니다. (CPAN 사용)
```
Algorithm::Diff
Class:Singleton
DBI and DBD::mysql
Data::Dumper
Date::Format
Date::Language
Date::Parse
ExtUtils::CBuilder
File::Basename
File::stat
File::Temp
Log::Dispatch
Log::Log4perl
Mail::Send
Module::Build
Net::ARP
Net::Ping
Params::Validate
Proc::Daemon
Thread::Queue
Time::HiRes
```

#### 3) mysql-mmm manual
- 기본적인 동작은 mysql-mmm과 유사하므로, mysql-mmm의 manual을 참고해도 됩니다.
- http://mysql-mmm.org/_media/:mmm2:mysql-mmm-2.2.1.pdf
