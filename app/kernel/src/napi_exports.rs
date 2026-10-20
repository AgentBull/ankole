use napi::Error;
use napi::bindgen_prelude::{AsyncTask, Result};
use napi::{Env, Task};
use napi_derive::napi;

use crate::{common, web_proxy};

#[napi(object)]
pub struct WebURLFacts {
    pub scheme: String,
    pub host: Option<String>,
    pub host_class: Option<String>,
}

#[napi(js_name = "webURLFacts")]
pub fn web_url_facts(url: String) -> Result<WebURLFacts> {
    let facts =
        common::web_url_facts(&url).map_err(|error| Error::from_reason(error.to_string()))?;
    Ok(WebURLFacts {
        scheme: facts.scheme,
        host: facts.host,
        host_class: facts.host_class.map(|class| class.as_str().to_string()),
    })
}

#[napi(js_name = "validateWebURL")]
pub fn validate_web_url(url: String, schemes: Vec<String>, ssrf_filter: bool) -> Option<String> {
    let schemes: Vec<&str> = schemes.iter().map(String::as_str).collect();
    common::validate_web_url(&url, &schemes, ssrf_filter)
        .err()
        .map(|reason| reason.as_str().to_string())
}

#[napi(js_name = "validateIPAddresses")]
pub fn validate_ip_addresses(addresses: Vec<String>, ssrf_filter: bool) -> Option<String> {
    let addresses: std::result::Result<Vec<std::net::IpAddr>, _> =
        addresses.iter().map(|address| address.parse()).collect();
    addresses
        .map_err(|_| common::WebURLRejection::Invalid)
        .and_then(|addresses| common::validate_ip_addresses(&addresses, ssrf_filter))
        .err()
        .map(|reason| reason.as_str().to_string())
}

#[napi]
pub struct WebProxy {
    proxy: web_proxy::WebProxy,
}

#[napi]
impl WebProxy {
    #[napi(getter)]
    pub fn port(&self) -> u32 {
        u32::from(self.proxy.port())
    }

    #[napi]
    pub fn close(&self) -> AsyncTask<CloseWebProxy> {
        AsyncTask::new(CloseWebProxy(self.proxy.stop()))
    }
}

pub struct CloseWebProxy(Option<tokio::task::JoinHandle<()>>);

impl Task for CloseWebProxy {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<()> {
        if let Some(task) = self.0.take() {
            let runtime = common::io_runtime::runtime()
                .map_err(|error| Error::from_reason(error.to_string()))?;
            let _ = runtime.block_on(task);
        }
        Ok(())
    }

    fn resolve(&mut self, _env: Env, _output: ()) -> Result<()> {
        Ok(())
    }
}

#[napi(js_name = "startWebProxy")]
pub fn start_web_proxy(ssrf_filter: bool, port: Option<u32>) -> Result<WebProxy> {
    let port = u16::try_from(port.unwrap_or(0))
        .map_err(|_| Error::from_reason("invalid browser proxy port"))?;
    let proxy = web_proxy::WebProxy::start(port, ssrf_filter)
        .map_err(|error| Error::from_reason(error.to_string()))?;
    Ok(WebProxy { proxy })
}

/// Counts o200k_base tokens for one text.
///
/// This is the Node binding of `common::estimate_o200k_base_tokens`.
/// It does not select a model.
#[napi(js_name = "estimateO200kBaseTokens")]
pub fn estimate_o200k_base_tokens(text: String) -> Result<u32> {
    u32::try_from(crate::common::estimate_o200k_base_tokens(&text))
        .map_err(|_| Error::from_reason("o200k_base token count is larger than 4294967295"))
}

#[cfg(test)]
mod tests {
    use super::estimate_o200k_base_tokens;

    #[test]
    fn node_binding_counts_known_text() {
        assert_eq!(
            estimate_o200k_base_tokens("Hello world".to_string()).unwrap(),
            2
        );
        assert_eq!(
            estimate_o200k_base_tokens("记忆系统".to_string()).unwrap(),
            3
        );
        assert_eq!(estimate_o200k_base_tokens(String::new()).unwrap(), 0);
    }
}
