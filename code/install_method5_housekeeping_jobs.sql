prompt Creating Method5 housekeeping jobs...


---------------------------------------
--#0: Check the user.
@code/check_user must_be_m5_user
set serveroutput off;


---------------------------------------
--#1: Create JOB to clean-up temporary tables created to hold results.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.cleanup_m5_temp_tables_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=0; byminute=05; bysecond=0',
		enabled         => true,
		comments        => 'Cleans up tmeporary tables created to hold Method5 results.',
		job_action      => q'<
			--Cleanup Method5 temporary tables.
			begin
				for tables_to_drop in
				(
					--Method5 temporary tables that can be cleaned up.
					--
					--Tables that start with "M5_TEMP_%", are over 1 day old, and are not referenced
					--by any objects.
					select 'drop table "'||owner||'".M5_TEMP_'||replace(object_name, 'M5_TEMP_')||' purge' v_sql
					from dba_objects
					where object_name like 'M5\_TEMP\_%' escape '\'
						and object_type = 'TABLE'
						--Created over a day ago.
						and created < sysdate - 1
						--Not part of any views or other dependency.
						and (owner, object_name) not in
						(
							select referenced_owner, referenced_name
							from dba_dependencies
						)
					order by 1
				) loop
					execute immediate tables_to_drop.v_sql;
				end loop;
			end;
		>'
	);
end;
/


---------------------------------------
--#2: Create JOB to clean-up temporary triggers used to copy auditing data.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.cleanup_m5_temp_triggers_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=0; byminute=10; bysecond=0',
		enabled         => true,
		comments        => 'Cleans up temporary triggers created to record audit information for Method5.',
		job_action      => q'<
			--Cleanup Method5 temporary triggers.
			begin
				for triggers_to_drop in
				(
					--Method5 temporary triggers that can be cleaned up.
					--
					--Triggers like "M5_TEMP_%_TRG" and are over 2 days old.
					select 'drop trigger METHOD5.'||object_name v_sql
					from dba_objects
					where object_name like 'M5\_TEMP\_%\_TRG%' escape '\'
						and object_type = 'TRIGGER'
						--Created over 2 days ago.
						and created < sysdate - 2
						--Owned by METHOD5.
						and owner = 'METHOD5'
						--If the trigger becomes invalid then it is not possible to drop it.
						--I am not sure why this happens, but it can generate this error:
						--ORA-00600: internal error code, arguments: [15239], ...						
						and status = 'VALID'
					order by 1
				) loop
					execute immediate triggers_to_drop.v_sql;
				end loop;
			end;
		>'
	);
end;
/


---------------------------------------
--#3: Create JOB to grant and revoke direct grants to Method5 objects.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.direct_m5_grants_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=0; byminute=15; bysecond=0',
		enabled         => true,
		comments        => 'Grant and revoke direct grants to Method5 objects.',
		job_action      => q'<
			begin
				for grants_and_revokes in
				(
					--Grant and revoke direct access to Method5 objects to all users with DBA role.
					--This direct access does not add any privileges, it only simplifies building procedures.
					--
					with expected_grants as
					(
						--Expected grants.
						select username grantee, table_name, privilege, grantable
						from method5.m5_user
						join dba_users
							on trim(upper(m5_user.oracle_username)) = dba_users.username
							and account_status not like '%LOCK'
						cross join
						(
							select 'M5'                  table_name, 'EXECUTE' privilege, 'NO'  grantable from dual union all
							select 'M5_DATABASE'         table_name, 'SELECT'  privilege, 'NO' grantable from dual union all
							select 'M5_GENERIC_SEQUENCE' table_name, 'SELECT'  privilege, 'NO'  grantable from dual union all
							select 'M5_PROC'             table_name, 'EXECUTE' privilege, 'NO'  grantable from dual union all
							select 'M5_PKG'              table_name, 'EXECUTE' privilege, 'NO'  grantable from dual
						)
						order by grantee, table_name
					),
					actual_grants as
					(
						--Actual grants.
						select grantee, table_name, privilege, grantable
						from dba_tab_privs
						where owner = 'METHOD5'
							and table_name in ('M5', 'M5_DATABASE', 'M5_GENERIC_SEQUENCE', 'M5_PROC', 'M5_PKG')
							and grantor = 'METHOD5'
						order by grantee, table_name
					)
					--Grants needed.
					select 'grant '||privilege||' on method5.'||table_name||' to '||grantee||
						case when grantable = 'YES' then ' with grant option' else null end grant_or_revoke_sql
					from
					(
						select grantee, table_name, privilege, grantable from expected_grants
						minus
						select grantee, table_name, privilege, grantable from actual_grants
					)
					union all
					--Revokes needed.
					select 'revoke '||privilege||' on method5.'||table_name||' from '||grantee grant_or_revoke_sql
					from
					(
						select grantee, table_name, privilege
						from actual_grants
						where table_name <> 'M5_DATABASE' --This table may be safe to grant.
							and grantee <> 'M5_RUN'       --This application role is safe.
						minus
						select grantee, table_name, privilege
						from expected_grants
					)
					order by 1
				) loop
					execute immediate grants_and_revokes.grant_or_revoke_sql;
				end loop;
			end;
		>'
	);
end;
/


---------------------------------------
--#4: Create JOB to cleanup remote Method5 objects.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'cleanup_remote_m5_objects_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=0; byminute=20; bysecond=0',
		enabled         => true,
		comments        => 'Cleanup old Method5 objects and temporary users that are sometimes left on the target databases if there was an error.',
		job_action      => q'<
			begin
				m5_proc(
					p_table_name => 'cleanup_remote_m5_objects',
					p_table_exists_action => 'DROP',
					p_targets => '%',
					p_code => 
					q'[
						begin
							for objects_to_drop in
							(
								--Drop old, temporary Method5 objects.
								--Normally Method5 will clean up after itself, but in some exceptional cases objects will remain.
								select
									case
										when object_type = 'TABLE' then
											'drop table method5.m5_temp_table_'||sequence_number||' purge'
										when object_type = 'FUNCTION' then
											'drop function method5.m5_temp_function_'||sequence_number
									end v_sql
								from
								(
									--Old objects.
									select replace(replace(object_name, 'M5_TEMP_FUNCTION_'), 'M5_TEMP_TABLE_') sequence_number, object_type
									from user_objects
									where object_type in ('TABLE', 'FUNCTION')
										and (object_name like 'M5_TEMP_FUNCTION_%' or object_name like 'M5_TEMP_TABLE_%')
										and created < sysdate - 7
								)
								union all
								--Drop old, temporary Method5 users.
								select 'drop user m5_temp_sandbox_'||replace(username, 'M5_TEMP_SANDBOX_')||' cascade' v_sql
								from dba_users
								where username like 'M5_TEMP_SANDBOX%'
									and created < sysdate - 7
								order by v_sql
							) loop
								execute immediate objects_to_drop.v_sql;
							end loop;
						end;
					]'
				);
			end;
		>'
	);
end;
/


---------------------------------------
--#5: Create JOB to send daily summary email.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.email_m5_daily_summary_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		--Set this after all the global data dictionary jobs.
		repeat_interval => 'freq=daily; byhour=4; byminute=0; bysecond=0',
		enabled         => true,
		comments        => 'Email a daily summary of Method5 activity.',
		job_action      => '
			begin
				method5.method5_admin.send_daily_summary_email;
			end;
		'
	);
end;
/


---------------------------------------
--#6: Create JOB to stop timed out jobs.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.stop_timed_out_jobs_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=minutely; interval=5;',
		enabled         => true,
		comments        => 'Stop timed out Method5 jobs.',
		job_action      =>
		q'[
			--Record and stop jobs that timd out.
			declare
				v_timeout_seconds number;
				v_must_be_a_job exception;
				pragma exception_init(v_must_be_a_job, -27475);
			begin
				--Get the timeout setting.
				select number_value
				into v_timeout_seconds
				from method5.m5_config
				where config_name = 'Job Timeout (seconds)';

				--Record and kill Method5 jobs that are too old.
				for jobs_to_kill in
				(
					select dba_scheduler_running_jobs.job_name, dba_scheduler_running_jobs.owner, comments, start_date
						,lower(regexp_replace(dba_scheduler_running_jobs.job_name, 'M5\_(.*)\_.*', '\1')) database_name
					from sys.dba_scheduler_running_jobs
					join sys.dba_scheduler_jobs
						on dba_scheduler_running_jobs.job_name = dba_scheduler_jobs.job_name
						and dba_scheduler_running_jobs.owner = dba_scheduler_jobs.owner
					where dba_scheduler_jobs.auto_drop = 'TRUE'
						and dba_scheduler_running_jobs.job_name like 'M5%'
						and dba_scheduler_running_jobs.owner <> 'METHOD5'
						and dba_scheduler_jobs.comments is not null
						and dba_scheduler_running_jobs.elapsed_time > v_timeout_seconds * interval '1' second
					order by dba_scheduler_jobs.owner, dba_scheduler_jobs.job_name
				) loop
					--Create a record of the timeout.
					insert into method5.m5_job_timeout(job_name, owner, database_name, table_name, start_date, stop_date)
					values (jobs_to_kill.job_name, jobs_to_kill.owner, jobs_to_kill.database_name,
						jobs_to_kill.comments, jobs_to_kill.start_date, systimestamp);
					commit;
					
					--Stop the job.
					begin
						sys.dbms_scheduler.stop_job(
							job_name => jobs_to_kill.owner||'.'||jobs_to_kill.job_name,
							force => true
						);
					exception when v_must_be_a_job then
						--Ignore errors caused when a job finishes between the query and the STOP_JOB.
						null;
					end;
				end loop;
			end;
		]'
	);
end;
/


---------------------------------------
--#7: Create JOB to backup M5_DATABASE.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.backup_m5_database_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=1; byminute=0; bysecond=0',
		enabled         => true,
		comments        => 'Backup M5_DATABASE table into M5_DATABASE_HIST.',
		job_action      => q'<
			begin
				insert into method5.m5_database_hist
				select sysdate, m5_database.* from method5.m5_database;
				commit;
			end;
		>'
	);
end;
/


---------------------------------------
--#8: Create JOB to drop unused database links.
begin
	dbms_scheduler.create_job
	(
		job_name        => 'method5.cleanup_unused_m5_links_job',
		job_type        => 'PLSQL_BLOCK',
		start_date      => systimestamp at time zone 'US/Eastern',
		repeat_interval => 'freq=daily; byhour=0; byminute=25; bysecond=0',
		enabled         => true,
		comments        => 'Drop M5 links for inactive users or inactive targets.',
		job_action      =>
		q'<
			--Drop links for inactive users or inactive targets.
			begin
				--Drop Method5 links for users who are no longer authorized to use Method5.
				for unauthorized_links in
				(
					--Users that are not authorized to have Method5 links.
					--
					--Method5 users with links.
					select distinct owner username
					from dba_db_links
					where db_link like 'M5%'
						and username = 'METHOD5'
						and db_link not like 'M5_SYS_KEY%'
						and db_link not like 'M5_INSTALL_DB_LINK%'
						and owner not in ('METHOD5', 'SYS', 'M5_TEST_DIRECT')
					minus
					--Authorized Method5 users
					select upper(trim(oracle_username)) from method5.m5_user
					order by 1
				) loop
					method5.method5_admin.drop_m5_db_links_for_user(unauthorized_links.username);
				end loop;


				--Drop Method5 links for databases or hosts that are no longer active.
				for links_to_drop in
				(
					--Links that shouldn't exist.
					select owner, partial_db_link, full_db_link
					from
					(
						--Active links.
						select owner, regexp_replace(db_link, '\..*') partial_db_link, db_link full_db_link
						from dba_db_links
						where db_link like 'M5%'
							and db_link not like 'M5_SYS_KEY%'
							and db_link not like 'M5_INSTALL_DB_LINK%'
					)
					where partial_db_link not in
					(
						--Allowed links
						select distinct upper(trim('M5_' || host_name)) partial_name
						from m5_database
						where is_active = 'Yes'
						union all
						select distinct upper(trim('M5_' || database_name))
						from m5_database
						where is_active = 'Yes'
					)
					order by 1,2
				) loop
					--Create the procedure.
					execute immediate
						replace(replace(q'[
							create or replace procedure #OWNER#.temp_drop_db_link is
							begin
								execute immediate 'drop database link #DB_LINK#';
							end;
						]'
						, '#DB_LINK#', links_to_drop.full_db_link)
						, '#OWNER#', links_to_drop.owner);

					--Call the procedure.
					execute immediate replace('
						begin #OWNER#.temp_drop_db_link; end;
					', '#OWNER#', links_to_drop.owner);

					--Drop the procedure.
					execute immediate replace('
						drop procedure #OWNER#.temp_drop_db_link
					', '#OWNER#', links_to_drop.owner);
				end loop;
			end;
		>'
	);
end;
/


---------------------------------------
--#9: Run jobs immediately to test them.
--Run job immediately to test the job.
prompt Running jobs...

begin
	dbms_scheduler.run_job('method5.cleanup_m5_temp_triggers_job');
end;
/
begin
	dbms_scheduler.run_job('method5.cleanup_m5_temp_tables_job');
end;
/
begin
	dbms_scheduler.run_job('method5.direct_m5_grants_job');
end;
/
begin
	dbms_scheduler.run_job('cleanup_remote_m5_objects_job');
end;
/
begin
	dbms_scheduler.run_job('method5.email_m5_daily_summary_job');
end;
/
begin
	dbms_scheduler.run_job('method5.stop_timed_out_jobs_job');
end;
/
begin
	dbms_scheduler.run_job('method5.backup_m5_database_job');
end;
/
begin
	dbms_scheduler.run_job('method5.cleanup_unused_m5_links_job');
end;
/


prompt Checking job statuses (these should all say SUCCEEDED)...

col job_name format a30;
col log_date format a18;
col status format a9;
set pagesize 1000;

select
	expected_jobs.job_name,
	to_char(log_date, 'YYYY-MM-DD HH24:MI') log_date,
	status,
	case when log_date is null then 'Error - the job has never run' else additional_info end additional_info
from
(
	select column_value job_name
	from table(sys.odcivarchar2list(
		'CLEANUP_M5_TEMP_TRIGGERS_JOB',
		'CLEANUP_M5_TEMP_TABLES_JOB',
		'DIRECT_M5_GRANTS_JOB',
		'CLEANUP_REMOTE_M5_OBJECTS_JOB',
		'EMAIL_M5_DAILY_SUMMARY_JOB',
		'STOP_TIMED_OUT_JOBS_JOB',
		'BACKUP_M5_DATABASE_JOB',
		'CLEANUP_UNUSED_M5_LINKS_JOB'
	))
) expected_jobs
left join
(
	select *
	from
	(
		select job_name, log_date, status, additional_info
			,row_number() over (partition by job_name order by log_date desc) last_when_1
		from dba_scheduler_job_run_details
		where job_name in
		(
			'CLEANUP_M5_TEMP_TRIGGERS_JOB',
			'CLEANUP_M5_TEMP_TABLES_JOB',
			'DIRECT_M5_GRANTS_JOB',
			'CLEANUP_REMOTE_M5_OBJECTS_JOB',
			'EMAIL_M5_DAILY_SUMMARY_JOB',
			'STOP_TIMED_OUT_JOBS_JOB',
			'BACKUP_M5_DATABASE_JOB',
			'CLEANUP_UNUSED_M5_LINKS_JOB'
		)
	)
	where last_when_1 = 1
) actual_jobs
	on expected_jobs.job_name = actual_jobs.job_name
order by job_name;


prompt Done.
