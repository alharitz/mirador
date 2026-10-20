use std::env;
use std::process;

mod core;
pub mod storage;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        print_usage();
        process::exit(2);
    }
    let command = &args[1];
    match command.as_str() {
        "migrate" => {
            if let Err(e) = validate_config(env::var("DATABASE_URL").ok()) {
                eprintln!("mirador: {}", e);
                process::exit(1);
            }
            println!("not implemented yet");
            process::exit(1);
        }
        "run" => {
            if let Err(e) = validate_config(env::var("DATABASE_URL").ok()) {
                eprintln!("mirador: {}", e);
                process::exit(1);
            }
            println!("not implemented yet");
            process::exit(1);
        }
        "serve" => {
            if let Err(e) = validate_config(env::var("DATABASE_URL").ok()) {
                eprintln!("mirador: {}", e);
                process::exit(1);
            }
            if let Err(e) = serve_command(env::var("MIRADOR_API_TOKEN").ok()) {
                eprintln!("mirador: {}", e);
                process::exit(1);
            }
            println!("not implemented yet");
            process::exit(1);
        }
        _ => {
            print_usage();
            process::exit(2);
        }
    }
}

fn print_usage() {
    eprintln!("Usage: mirador <command>");
    eprintln!("Commands:");
    eprintln!("  migrate   Run database migrations");
    eprintln!("  run       Run application");
    eprintln!("  serve     Start HTTP server");
}

fn validate_config(database_url: Option<String>) -> Result<(), String> {
    let database_url = match database_url {
        Some(u) => u.trim().to_string(),
        None => return Err("DATABASE_URL is not set".to_string()),
    };

    if database_url.is_empty() {
        return Err("DATABASE_URL is not set".to_string());
    }

    if database_url
        .chars()
        .any(|c| c.is_whitespace() || c.is_control())
    {
        return Err("DATABASE_URL contains whitespace".to_string());
    }

    if !database_url.starts_with("postgres://") && !database_url.starts_with("postgresql://") {
        return Err("DATABASE_URL must start with postgres:// or postgresql://".to_string());
    }

    let rest = database_url
        .strip_prefix("postgres://")
        .or_else(|| database_url.strip_prefix("postgresql://"))
        .expect("database URL scheme validated");

    if rest.contains('#') {
        return Err("DATABASE_URL must not contain a fragment".to_string());
    }

    if let Some(pos) = rest.rfind('@') {
        let userinfo = &rest[..pos];
        // userinfo must not contain '/', '?', '#', or '@'
        if userinfo.contains('/')
            || userinfo.contains('?')
            || userinfo.contains('#')
            || userinfo.contains('@')
        {
            return Err("DATABASE_URL userinfo contains invalid character".to_string());
        }
        let user = match userinfo.find(':') {
            Some(i) => &userinfo[..i],
            None => userinfo,
        };
        if user.is_empty() {
            return Err("DATABASE_URL user is empty".to_string());
        }
    }

    let hostport_start = match rest.rfind('@') {
        Some(pos) => pos + 1,
        None => 0,
    };
    let hostport_and_db = &rest[hostport_start..];

    // Find the first '/' to split hostport and dbname, and also note if we found a '/'
    let (hostport, dbname_and_params, has_slash) = match hostport_and_db.find('/') {
        Some(pos) => (&hostport_and_db[..pos], &hostport_and_db[pos + 1..], true),
        None => (hostport_and_db, "", false),
    };

    if hostport.is_empty() {
        return Err("DATABASE_URL host is empty".to_string());
    }

    // Validate host and port
    if hostport.starts_with('[') {
        // IPv6 literal
        if let Some(end_bracket) = hostport.find(']') {
            let ipv6_part = &hostport[1..end_bracket];
            let rest_after_bracket = &hostport[end_bracket + 1..];
            // After the closing bracket, there must be nothing or a colon followed by a port.
            if !rest_after_bracket.is_empty() && !rest_after_bracket.starts_with(':') {
                return Err("DATABASE_URL host is malformed".to_string());
            }
            match ipv6_part.parse::<std::net::Ipv6Addr>() {
                Ok(_) => {}
                Err(_) => return Err("DATABASE_URL host is malformed".to_string()),
            }
            if let Some(port_str) = rest_after_bracket.strip_prefix(':') {
                match port_str.parse::<u16>() {
                    Ok(p) if (1..=65535).contains(&p) => {}
                    _ => return Err("DATABASE_URL port is invalid".to_string()),
                }
            }
        } else {
            return Err("DATABASE_URL host is malformed".to_string());
        }
    } else {
        // IPv4 or hostname
        let parts: Vec<&str> = hostport.splitn(2, ':').collect();
        let host_str = parts[0];
        let port_str = parts.get(1);
        if host_str.is_empty() {
            return Err("DATABASE_URL host is empty".to_string());
        }
        // host_str must not contain '/', '?', '#', '[', ']', or '\\'
        if host_str.contains('/')
            || host_str.contains('?')
            || host_str.contains('#')
            || host_str.contains('[')
            || host_str.contains(']')
            || host_str.contains('\\')
        {
            return Err("DATABASE_URL host is malformed".to_string());
        }
        // We could validate host_str as IPv4Addr, but it's optional; we'll accept any non-empty string.
        if let Some(port) = port_str {
            match port.parse::<u16>() {
                Ok(p) if (1..=65535).contains(&p) => {}
                _ => return Err("DATABASE_URL port is invalid".to_string()),
            }
        }
    }

    if !has_slash {
        return Err("DATABASE_URL must contain a database name".to_string());
    }

    let dbname = match dbname_and_params.find('?') {
        Some(pos) => &dbname_and_params[..pos],
        None => dbname_and_params,
    };

    if dbname.is_empty() {
        return Err("DATABASE_URL database name is empty".to_string());
    }

    Ok(())
}

fn serve_command(token: Option<String>) -> Result<(), String> {
    let token = match token {
        Some(t) => t.trim().to_string(),
        None => String::new(),
    };
    if token.is_empty() {
        return Err("token is required for serve command".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_missing_database_url() {
        assert_eq!(
            validate_config(None).err().unwrap(),
            "DATABASE_URL is not set"
        );
    }

    #[test]
    fn test_empty_database_url() {
        assert_eq!(
            validate_config(Some("".to_string())).err().unwrap(),
            "DATABASE_URL is not set"
        );
    }

    #[test]
    fn test_whitespace_in_database_url() {
        assert_eq!(
            validate_config(Some("postgres://host/db name".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL contains whitespace"
        );
    }

    #[test]
    fn test_invalid_scheme() {
        assert_eq!(
            validate_config(Some("mysql://host/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL must start with postgres:// or postgresql://"
        );
    }

    #[test]
    fn test_missing_host() {
        assert_eq!(
            validate_config(Some("postgres:///db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is empty"
        );
    }

    #[test]
    fn test_missing_database_name() {
        assert_eq!(
            validate_config(Some("postgres://host".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL must contain a database name"
        );
    }

    #[test]
    fn test_empty_database_name() {
        assert_eq!(
            validate_config(Some("postgres://host/".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL database name is empty"
        );
    }

    #[test]
    fn test_valid_database_url() {
        assert!(
            validate_config(Some("postgres://user:pass@localhost:5432/mydb".to_string())).is_ok()
        );
    }

    #[test]
    fn test_valid_database_url_with_query() {
        assert!(validate_config(Some("postgresql://host/db?sslmode=disable".to_string())).is_ok());
    }

    #[test]
    fn test_valid_database_url_without_userinfo() {
        assert!(validate_config(Some("postgres://host/db".to_string())).is_ok());
    }

    #[test]
    fn test_serve_missing_token() {
        assert_eq!(
            serve_command(None).err().unwrap(),
            "token is required for serve command"
        );
    }

    #[test]
    fn test_serve_empty_token() {
        assert_eq!(
            serve_command(Some("".to_string())).err().unwrap(),
            "token is required for serve command"
        );
    }

    #[test]
    fn test_serve_valid_token() {
        assert!(serve_command(Some("valid-token".to_string())).is_ok());
    }

    #[test]
    fn test_fragment_in_database_url() {
        assert_eq!(
            validate_config(Some("postgres://host/db#frag".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL must not contain a fragment".to_string()
        );
    }

    #[test]
    fn test_malformed_port_non_numeric() {
        assert_eq!(
            validate_config(Some("postgres://host:abc/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL port is invalid".to_string()
        );
    }

    #[test]
    fn test_malformed_port_out_of_range() {
        assert_eq!(
            validate_config(Some("postgres://host:70000/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL port is invalid".to_string()
        );
    }

    #[test]
    fn test_broken_ipv6_missing_bracket() {
        assert_eq!(
            validate_config(Some("postgres://[::1/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is malformed".to_string()
        );
    }

    #[test]
    fn test_broken_ipv6_invalid_address() {
        assert_eq!(
            validate_config(Some("postgres://[gggg]/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is malformed".to_string()
        );
    }

    #[test]
    fn test_empty_user() {
        assert_eq!(
            validate_config(Some("postgres://:pass@host/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL user is empty".to_string()
        );
    }

    #[test]
    fn test_host_unmatched_closing_bracket() {
        assert_eq!(
            validate_config(Some("postgres://host]/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is malformed".to_string()
        );
    }

    #[test]
    fn test_host_backslash() {
        assert_eq!(
            validate_config(Some("postgres://host\\\\bad/db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is malformed".to_string()
        );
    }

    #[test]
    fn test_host_unmatched_opening_bracket() {
        assert_eq!(
            validate_config(Some("postgres://host[db".to_string()))
                .err()
                .unwrap(),
            "DATABASE_URL host is malformed".to_string()
        );
    }
}
