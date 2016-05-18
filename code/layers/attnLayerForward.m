function [attnInfo] = attnLayerForward(h_t, params, model, attnData, maskInfo)
%
% Attentional Layer: from lstm hidden state to softmax hidden state.
% Input: 
%   attnData: require attnData.srcHidVecsOrig and attnData.srcLens
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
%
  attnInfo = [];
  if params.attnGlobal % global
    srcHidVecs = attnData.srcHidVecsOrig;
    % attnInfo.srcMaskedIds = [];
    attnInfo.srcMaskedIds = find(attnData.srcMask(:, 1:params.numSrcHidVecs)'==0); % numSrcHidVecs * curBatchSize
  else % local
    [mu, attnInfo] = regressPositions(model, h_t, attnData.srcLens, params);
    srcPositions = floor(mu);
    
    % assert
    if params.assert
      assert(isempty(find(srcPositions<1,1)));
      assert(isempty(find(srcPositions(maskInfo.unmaskedIds)>(attnData.srcLens(maskInfo.unmaskedIds)-1),1)));
    end
      
    % reverse
    if params.isReverse
      srcPositions = params.srcMaxLen - srcPositions;
    end

    % build context vectors
    [srcHidVecs, attnInfo] = buildSrcVecs(attnData.srcHidVecsOrig, srcPositions, maskInfo, attnData.srcLens, params.srcMaxLen, params, attnInfo);

    attnInfo.srcMaskedIds = find(attnInfo.alignMask==0);
  end % end else if attnGlobal
  
  % compute alignScores: numAttnPositions * curBatchSize
  % TODO: precompute for attnOpt2 and attnOpt3 (we can premultiply srcHidVecs with W_a (attnOpt2) or W_a_src (attnOpt3)
  if params.attnOpt==1 || params.attnOpt==2 % dot product or general dot product
    if params.attnOpt==1 % dot product
      [alignScores] = srcCompareLayerForward(srcHidVecs, h_t, params);
    elseif params.attnOpt==2 % general dot product
      attnInfo.transform_ht = model.W_a * h_t; % TODO: shift the multiplication to srcHidVecs
      [alignScores] = srcCompareLayerForward(srcHidVecs, attnInfo.transform_ht, params);
    end
  elseif params.attnOpt==3 % Bengio's style
    % f(H_src + W_a*h_t): lstmSize * (curBatchSize * numAttnPositions))
    attnInfo.src_ht_hid = reshape(params.nonlinear_f(bsxfun(@plus, srcHidVecs, model.W_a*h_t)), params.lstmSize, []);

    % v_a * src_ht_hid
    alignScores = linearLayerForward(model.v_a, attnInfo.src_ht_hid); % 1 * (curBatchSize * numAttnPositions)
    alignScores = reshape(alignScores, params.curBatchSize, params.numAttnPositions)'; % numAttnPositions * curBatchSize
  end  
  
  % normalize -> alignWeights
  attnInfo.alignWeights = normLayerForward(alignScores, attnInfo.srcMaskedIds);

  % local, regression, multiply with distWeights
  if params.attnGlobal == 0
    [attnInfo.distWeights, attnInfo.scaleX] = distLayerForward(mu, attnInfo, params); % numAttnPositions*curBatchSize
    attnInfo.preAlignWeights = attnInfo.alignWeights;
    
    if params.normLocalAttn % normalize
      attnInfo.unNormAlignWeights =  attnInfo.preAlignWeights.* attnInfo.distWeights; % weighted by distances
      attnInfo.alignWeights = normLayerForward(attnInfo.unNormAlignWeights, attnInfo.srcMaskedIds);
    else % unnormalize, EMNLP'15
      attnInfo.alignWeights = attnInfo.preAlignWeights.* attnInfo.distWeights; % weighted by distances
    end
  end

  % assert
  if params.assert
    assert(computeSum(attnInfo.alignWeights(attnInfo.srcMaskedIds), params.isGPU)==0);
  end
  
  attnInfo.alignWeights(:, maskInfo.maskedIds) = 0;
  % alignWeights, srcHidVecs -> contextVecs
  [contextVecs] = contextLayerForward(attnInfo.alignWeights, srcHidVecs, maskInfo.unmaskedIds, params);

  % f(W_h*[context_t; h_t])
  attnInfo.input = [contextVecs; h_t];
  attnInfo.h_t = h_t;
  attnInfo.softmax_h = hiddenLayerForward(model.W_h, attnInfo.input, params.nonlinear_f);

  % assert
  if params.assert
    assert(isequal(size(attnInfo.alignWeights), [params.numAttnPositions, params.curBatchSize]));
    assert(isequal(size(h_t), size(contextVecs))); % lstmSize * curBatchSize
  end
end

function [mu, h2sInfo] = regressPositions(model, h_t, srcLens, params)
  % h_t -> scales=sigmoid(v_pos*f(W_pos*h_t)) in [0, 1]
  [h2sInfo.scales, h2sInfo.posForwData] = scaleLayerForward(model.W_pos, model.v_pos, h_t, params);

  % scales -> srcPositions
  mu = h2sInfo.scales.*(srcLens-1) + 1;
end
