create extension pgcrypto;

create table users (
	id bigserial,
	powder_id bigint
		not null,
	name text
		not null,
	name_fetched_at timestamp with time zone
		not null
		default transaction_timestamp(),
	max_scripts integer
		not null
		default 10,
	max_script_bytes integer
		not null
		default 100000,
	locked boolean
		not null
		default false,
	constraint users_powder_id_uq unique (powder_id),
	constraint users_id_pk primary key (id)
);

create function lazy_register_user(
	in powder_id_in bigint,
	in name_in text
) returns bigint language plpgsql as $$ declare
	user_id bigint;
begin
	insert into users (powder_id, name)
		values (powder_id_in, name_in)
		on conflict on constraint users_powder_id_uq do update set
			name = excluded.name,
			name_fetched_at = transaction_timestamp()
			where
				users.name <> excluded.name;
	-- The statement above locks the row, we can select this without races.
	select id
		into user_id
		from users
		where powder_id = powder_id_in;
	return user_id;
end; $$;

create table scripts (
	id bigserial,
	tag uuid
		not null
		default gen_random_uuid(),
	blob uuid
		not null,
	created_at timestamp with time zone
		not null
		default transaction_timestamp(),
	updated_at timestamp with time zone
		not null
		default transaction_timestamp(),
	module text
		constraint scripts_module_length check (length(module) between 1 and 100)
		constraint scripts_module_syntax check (module similar to '[a-zA-Z_][a-zA-Z_0-9]*')
		not null,
	title text
		not null
		constraint scripts_title_length check (length(title) between 1 and 100),
	description text
		not null
		constraint scripts_description_length check (length(description) between 1 and 500),
	dependencies text
		not null
		constraint scripts_dependencies_length check (length(dependencies) between 0 and 500),
	listed boolean
		not null,
	data bytea
		not null,
	version bigint
		not null
		default 0,
	user_id bigint
		not null,
	staff_approved boolean
		not null
		default false,
	constraint scripts_module_uq unique (module),
	constraint scripts_user_id_fk foreign key (user_id) references users (id),
	constraint scripts_id_pk primary key (id)
);

create type manage_script_action as enum (
	'upsert',
	'delete'
);
create type manage_script_status as enum (
	'ok',
	'user_locked',
	'too_many_scripts',
	'too_much_script_data',
	'module_too_long',
	'bad_module',
	'title_too_long',
	'description_too_long',
	'dependencies_too_long',
	'no_access',
	'no_user'
);
create type manage_script_result as (
	status manage_script_status,
	new_blob uuid,
	old_blob uuid
);
create function manage_script(
	in action manage_script_action,
	in user_id_in bigint,
	in module_in text,
	in title_in text,
	in description_in text,
	in dependencies_in text,
	in listed_in boolean,
	in data_in bytea,
	in bypass_owner_check boolean
) returns manage_script_result language plpgsql as $$ declare
	result manage_script_result;
	user_id_check bigint;
	user_locked_check boolean;
begin
	-- Try to lock the user row for share so it doesn't disappear while we add a script that references it.
	select id, locked
		into user_id_check, user_locked_check
		from users
		where id = user_id_in
		for share;
	if user_id_check is null then
		result.status = 'no_user';
		return result;
	end if;
	if user_locked_check and not bypass_owner_check then
		result.status = 'user_locked';
		return result;
	end if;
	if action = 'upsert' then
		declare
			script_id bigint;
			new_version bigint;
			new_blob uuid;
			blob_out uuid;
		begin
			new_blob = gen_random_uuid();
			-- This is magical: in all possible cases, the row we get is locked
			-- least at the "for no key update" strength. We either
			--  - insert here, in which case other transactions won't see it until we
			--    commit, but also won't be able to proceed if they try to commit the
			--    same powder_id, and will try to lock the row for update, or
			--  - update here, in which case we lock the row for update.
			-- We lock the row for update even on conflict when the update condition
			-- evaluates to false; the manual says all rows that are considered for
			-- updating get locked.
			insert into scripts (user_id, module, title, description, dependencies, listed, data, blob)
				values (user_id_in, module_in, title_in, description_in, dependencies_in, listed_in, data_in, new_blob)
				on conflict on constraint scripts_module_uq do update set
					version = scripts.version + 1,
					title = title_in,
					description = description_in,
					dependencies = dependencies_in,
					listed = listed_in,
					data = data_in,
					updated_at = transaction_timestamp(),
					staff_approved = false -- Reset this every update.
					where scripts.user_id = user_id_in or bypass_owner_check
				returning id, blob, version
					into script_id, blob_out, new_version;
			if script_id is null then
				-- This happens if the update predicate evaluates to false. In this case,
				-- this means the script exists but isn't owner by user_id_in.
				result.status = 'no_access';
			elseif new_version = 0 then
				result.status = 'ok';
				result.new_blob = new_blob;
			else
				result.status = 'ok';
				result.new_blob = new_blob;
				-- The conflict update doesn't update the row's blob, so it's still the old one.
				result.old_blob = blob_out;
				update scripts set
					blob = new_blob
					where id = script_id;
			end if;
		exception
		when raise_exception then
			case sqlerrm
			when 'too_many_scripts' then
				result.status = 'too_many_scripts';
			when 'too_much_script_data' then
				result.status = 'too_much_script_data';
			end case;
		when check_violation then
			declare
				constraint_name_str text;
			begin
				get stacked diagnostics constraint_name_str = constraint_name;
				case constraint_name_str
				when 'scripts_module_length' then
					result.status = 'module_too_long';
				when 'scripts_module_syntax' then
					result.status = 'bad_module';
				when 'scripts_title_length' then
					result.status = 'title_too_long';
				when 'scripts_description_length' then
					result.status = 'description_too_long';
				when 'scripts_dependencies_length' then
					result.status = 'dependencies_too_long';
				end case;
			end;
		end;
	else -- So action = 'delete'.
		declare
			script_id bigint;
			script_user_id bigint;
			blob_out uuid;
		begin
			select id, user_id, blob
				into script_id, script_user_id, blob_out
				from scripts
				where module = module_in
				for update;
			if script_id is null then
				result.status = 'ok'; -- Deletion is idempotent.
			elseif script_user_id <> user_id_in and not bypass_owner_check then
				result.status = 'no_access';
			else
				-- Row locked by the select, we can delete without races.
				delete from scripts
					where id = script_id;
				result.status = 'ok';
				result.old_blob = blob_out;
			end if;
		end;
	end if;
	return result;
end; $$;

create procedure enforce_user_script_limits(
	in user_id_in bigint
) language plpgsql as $$ begin
	if (select count(*) from scripts where user_id = user_id_in) >
		(select max_scripts from users where id = user_id_in) then
		raise exception 'too_many_scripts';
	end if;
	if (select sum(length(data)) from scripts where user_id = user_id_in) >
		(select max_script_bytes from users where id = user_id_in) then
		raise exception 'too_much_script_data';
	end if;
end; $$;

create function scripts_enforce_limits_triggerfunc() returns trigger language plpgsql as $$ begin
	call enforce_user_script_limits(new.user_id);
	return new;
end; $$;

create trigger scripts_enforce_script_count_trigger
	after insert -- Enforce users.max_scripts.
	on scripts
	for each row
	execute function scripts_enforce_limits_triggerfunc();

create trigger scripts_enforce_script_data_trigger
	after update
	on scripts
	for each row
	when (length(old.data) < length(new.data)) -- Enforce users.max_script_bytes.
	execute function scripts_enforce_limits_triggerfunc();

create trigger scripts_enforce_script_user_trigger
	after update
	on scripts
	for each row
	when (old.user_id <> new.user_id) -- Enforce both users.max_scripts and users.max_script_bytes.
	execute function scripts_enforce_limits_triggerfunc();

create function users_enforce_limits_triggerfunc() returns trigger language plpgsql as $$ begin
	call enforce_user_script_limits(new.id);
	return new;
end; $$;

create trigger users_enforce_script_data_trigger
	after update
	on users
	for each row
	when (old.max_script_bytes > new.max_script_bytes or -- Enforce users.max_script_bytes.
		old.max_scripts > new.max_scripts) -- Enforce users.max_scripts.
	execute function users_enforce_limits_triggerfunc();

create type staff_approve_script_status as enum (
	'ok',
	'no_script_version'
);
create function staff_approve_script(
	in module_in text,
	in version_in bigint,
	in approved_in boolean
) returns staff_approve_script_status language plpgsql as $$ declare
	script_id bigint;
begin
	update scripts set
		staff_approved = approved_in
		where module = module_in and (version = version_in or not approved_in)
		returning id
			into script_id;
	if script_id is null then
		return 'no_script_version';
	end if;
	return 'ok';
end; $$;

create type staff_user_max_scripts_status as enum (
	'ok',
	'no_user',
	'too_many_scripts'
);
create function staff_user_max_scripts(
	in powder_id_in bigint,
	in max_scripts_in bigint
) returns staff_user_max_scripts_status language plpgsql as $$ declare
	user_id bigint;
begin
	begin
		update users set
			max_scripts = max_scripts_in
			where powder_id = powder_id_in
			returning id
				into user_id;
	exception
	when raise_exception then
		case sqlerrm
		when 'too_many_scripts' then
			return 'too_many_scripts';
		end case;
	end;
	if user_id is null then
		return 'no_user';
	end if;
	return 'ok';
end; $$;

create type staff_user_max_script_bytes_status as enum (
	'ok',
	'no_user',
	'too_much_script_data'
);
create function staff_user_max_script_bytes(
	in powder_id_in bigint,
	in max_script_bytes_in bigint
) returns staff_user_max_script_bytes_status language plpgsql as $$ declare
	user_id bigint;
begin
	begin
		update users set
			max_script_bytes = max_script_bytes_in
			where powder_id = powder_id_in
			returning id
				into user_id;
	exception
	when raise_exception then
		case sqlerrm
		when 'too_much_script_data' then
			return 'too_much_script_data';
		end case;
	end;
	if user_id is null then
		return 'no_user';
	end if;
	return 'ok';
end; $$;

create type staff_user_locked_status as enum (
	'ok',
	'no_user'
);
create function staff_user_locked(
	in powder_id_in bigint,
	in locked_in boolean
) returns staff_user_locked_status language plpgsql as $$ declare
	user_id bigint;
begin
	update users set
		locked = locked_in
		where powder_id = powder_id_in
		returning id
			into user_id;
	if user_id is null then
		return 'no_user';
	end if;
	return 'ok';
end; $$;

create view manifest as
	select scripts.blob as blob,
		extract(epoch from scripts.created_at) as created_at,
		extract(epoch from scripts.updated_at) as updated_at,
		scripts.tag as tag,
		scripts.module as module,
		scripts.title as title,
		scripts.description as description,
		scripts.dependencies as dependencies,
		scripts.listed as listed,
		scripts.version as version,
		scripts.staff_approved as staff_approved,
		users.name as author,
		users.powder_id as author_id
		from scripts join users on scripts.user_id = users.id;
